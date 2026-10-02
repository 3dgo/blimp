package blimp

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:time"
import hm "core:container/handle_map"

// The probe baker (docs/rendering.md → Lighting, Baker). A CPU ray tracer over the level's static
// geometry (a Scene_BVH of the entities that pass entity_bakes) fills a uniform grid of L2 SH irradiance
// probes (render_probes.odin). Probes hold indirect light only — sky and bounces. Direct light stays
// realtime, so each light reaches a probe only off a surface it lit.
//
// Pass k: every probe casts BAKE_RAYS rays. A miss sees the sky. A hit on a front face sends back
// albedo × (direct light there + pass k-1's grid sampled there), so BAKE_PASSES passes are that many
// bounces. A back-face hit means the probe sees the inside of something; it sends back black.
// Passes run probes in parallel (parallel_for); each probe writes only its own slot.

BAKE_RAYS    :: 256    // per probe per pass, on a Fibonacci sphere: the same set for every probe, so bakes repeat exactly
BAKE_PASSES  :: 3      // bounces
BAKE_EPSILON :: 1e-3   // offset off a hit surface (metres) for its shadow rays and grid lookup

// A probe whose rays mostly hit back faces is inside geometry. Counted for the stats; nothing acts on
// it yet (docs/rendering.md → Baker: see the leaking before fixing it).
BAKE_BURIED_FRACTION :: 0.25

// What makes geometry block and bounce light in the bake: drawn, static, and not opted out.
entity_bakes :: proc(e: ^Entity) -> bool {
    return entity_drawn(e) && .Static in e.basic_static_flags && .Cast_Indirect in e.basic_static_flags
}

Bake_Stats :: struct {
    dims:      [3]i32,
    instances: int,   // entity-mesh pairs in the scene BVH
    lights:    int,
    layers:    int,   // probe layers: 1 + the light groups that have lights
    threads:   int,
    rays:      int,   // probe rays, all passes (shadow rays not counted)
    backface:  f32,   // last pass: share of probe rays that hit a back face
    buried:    int,   // probes with more than BAKE_BURIED_FRACTION of their rays on back faces
    seconds:   f64,
}

@(private="file")
Bake :: struct {
    scene:  Scene_BVH,
    lights: []GPU_Light,
    light_layer: []u8,            // each light's probe layer (its group's; layer 0 for group 0)
    layers: int,
    sky:    vec3,                 // linear radiance of a miss (layer 0)
    dirs:   [BAKE_RAYS]vec3,
    basis:  [BAKE_RAYS][9]f32,    // sh_basis(dirs[k])
    prev:   Probe_Grid,           // the previous pass (all zero on the first); only origin..probes are used
    out:    []Probe_SH,           // this pass, laid out like prev.probes
    back:   []u32,                // this pass: back-face hits per probe
}

Bake_Layers :: [MAX_PROBE_LAYERS]vec3   // one radiance (or irradiance) per probe layer

// Bakes w's probes and replaces its grid, its GPU copy and its .probes sidecar (when it has a save path).
// Blocks until done. Not an edit: no undo step, the world doesn't become unsaved. Call outside the frame
// (UI or remote command): it waits for the GPU.
//
// Light groups (world_light_groups.odin) bake into layers: layer 0 holds the sky and group-0 lights, and
// each group with a light gets its own. Light adds up, so a layer is exactly what its group gives, bounces
// included (a group's light bounces within its own layer), and the runtime scales each layer by its group.
bake_probes :: proc(w: ^World) -> (stats: Bake_Stats, ok: bool) {
    start := time.tick_now()
    b: Bake

    b.scene = scene_bvh_build(w, entity_bakes, context.temp_allocator)
    stats.instances = len(b.scene.instances)
    if len(b.scene.nodes) == 0 {
        log.errorf("Bake '%v': no static geometry (entities need Static, Cast Indirect and a model)", w.title)
        return
    }

    // Lights, and a layer for every group that has one: layer 0 first, then the groups in order.
    lights := make([dynamic]GPU_Light, 0, MAX_LIGHTS, context.temp_allocator)
    groups := make([dynamic]int, 0, MAX_LIGHTS, context.temp_allocator)
    has_group: [MAX_LIGHT_GROUPS + 1]bool
    it := hm.iterator_make(&w.entities)
    for e, _ in hm.iterate(&it) {
        if !entity_drawn(e) || e.light_type == .None || len(lights) == MAX_LIGHTS do continue
        append(&lights, entity_gpu_light(e))   // at its own intensity: the group scale is applied at runtime
        append(&groups, entity_light_group(e))
        has_group[entity_light_group(e)] = true
    }
    layer_group: [MAX_PROBE_LAYERS]u8
    group_layer: [MAX_LIGHT_GROUPS + 1]u8
    b.layers = 1
    for g in 1..=MAX_LIGHT_GROUPS do if has_group[g] {
        group_layer[g] = u8(b.layers)
        layer_group[b.layers] = u8(g)
        b.layers += 1
    }
    b.lights = lights[:]
    b.light_layer = make([]u8, len(lights), context.temp_allocator)
    for g, i in groups do b.light_layer[i] = group_layer[g]
    stats.lights, stats.layers = len(lights), b.layers
    b.sky = w.settings.bake.sky_color * w.settings.bake.sky_intensity

    // The grid covers the geometry's bounds plus one spacing all round.
    spacing := max(w.settings.bake.probe_spacing, 0.05)
    lo := b.scene.nodes[0].min - spacing
    hi := b.scene.nodes[0].max + spacing
    dims: [3]i32
    for a in 0..<3 do dims[a] = i32(math.ceil((hi[a] - lo[a]) / spacing)) + 1
    count := int(dims.x) * int(dims.y) * int(dims.z)
    stats.dims = dims
    if count > MAX_PROBES {
        log.errorf("Bake '%v': %v × %v × %v = %v probes is over MAX_PROBES (%v); raise the probe spacing", w.title, dims.x, dims.y, dims.z, count, MAX_PROBES)
        return
    }

    // Fibonacci sphere: even coverage, no clumping, no randomness.
    GOLDEN_ANGLE :: math.PI * (3 - 2.2360679775)   // π(3 − √5)
    for k in 0..<BAKE_RAYS {
        z := 1 - (2 * f32(k) + 1) / BAKE_RAYS
        r := math.sqrt(1 - z * z)
        phi := f32(k) * GOLDEN_ANGLE
        b.dirs[k] = {r * math.cos(phi), r * math.sin(phi), z}
        b.basis[k] = sh_basis(b.dirs[k])
    }

    b.prev = Probe_Grid{origin = lo, spacing = spacing, dims = dims, layers = i32(b.layers), layer_group = layer_group,
        probes = make([]Probe_SH, count * b.layers, context.temp_allocator)}
    b.out  = make([]Probe_SH, count * b.layers, context.temp_allocator)
    b.back = make([]u32, count, context.temp_allocator)

    for pass in 0..<BAKE_PASSES {
        stats.threads = parallel_for(count, &b, bake_probe)
        b.prev.probes, b.out = b.out, b.prev.probes   // this pass is the next one's light source
        log.infof("Bake '%v': pass %v/%v done (%.1f s)", w.title, pass + 1, BAKE_PASSES, time.duration_seconds(time.tick_since(start)))
    }
    stats.rays = count * BAKE_RAYS * BAKE_PASSES

    total_back := 0
    for n in b.back {
        total_back += int(n)
        if f32(n) > BAKE_BURIED_FRACTION * BAKE_RAYS do stats.buried += 1
    }
    stats.backface = f32(total_back) / f32(count * BAKE_RAYS)

    probe_grid_set(w, lo, spacing, dims, layer_group[:b.layers], b.prev.probes)
    world_render_probes_recreate(w)
    if w.save_path != "" {
        path := probes_path(w.save_path)
        if probe_grid_save(&w.probes, path) do log.infof("Saved probes '%v'", path)
    } else {
        log.warnf("Bake '%v': no level file to save the probes beside (a kit); they last until it closes", w.title)
    }

    stats.seconds = time.duration_seconds(time.tick_since(start))
    log.infof("Bake '%v': %v × %v × %v probes × %v layers, %v instances, %v lights, %v threads, %.1f s (%.2f M rays/s); back faces %.1f%%, %v buried",
        w.title, dims.x, dims.y, dims.z, b.layers, stats.instances, stats.lights, stats.threads, stats.seconds,
        f64(stats.rays) / stats.seconds / 1e6, 100 * stats.backface, stats.buried)
    return stats, true
}

// One probe, one pass, every layer (parallel_for body: no allocation, no logging).
@(private="file")
bake_probe :: proc(data: rawptr, i: int) {
    b := (^Bake)(data)
    g := &b.prev
    x := i32(i) % g.dims.x
    y := (i32(i) / g.dims.x) % g.dims.y
    z := i32(i) / (g.dims.x * g.dims.y)
    p := probe_position(g, x, y, z)

    sh: [MAX_PROBE_LAYERS][9]vec3
    back: u32
    for k in 0..<BAKE_RAYS {
        L := bake_radiance(b, Ray{origin = p, dir = b.dirs[k]}, &back)
        for l in 0..<b.layers do for c in 0..<9 do sh[l][c] += L[l] * b.basis[k][c]
    }
    // Monte Carlo over the sphere (× 4π / N), then irradiance = the cosine lobe convolved (bands × π,
    // 2π/3, π/4), stored / π: bands × 1, 2/3, 1/4.
    BAND := [9]f32{1, 2.0/3, 2.0/3, 2.0/3, 0.25, 0.25, 0.25, 0.25, 0.25}
    count := probe_count(g)
    for l in 0..<b.layers do for c in 0..<9 do b.out[l * count + i].c[c] = sh[l][c] * (4 * math.PI / BAKE_RAYS) * BAND[c]
    b.back[i] = back
}

// Radiance arriving along r, per layer. One trace serves them all; only what lights the hit differs.
@(private="file")
bake_radiance :: proc(b: ^Bake, r: Ray, back: ^u32) -> (L: Bake_Layers) {
    hit, ok := scene_bvh_closest_hit(&b.scene, r)
    if !ok {
        L[0] = b.sky
        return
    }

    // Front faces are clockwise seen from the front (left-handed, Y-up): cross(v1 − v0, v2 − v0) faces out.
    tri := scene_hit_triangle(&b.scene, hit)
    n := linalg.normalize(linalg.cross(tri[1] - tri[0], tri[2] - tri[0]))
    if linalg.dot(n, r.dir) >= 0 {
        back^ += 1
        return
    }

    p := r.origin + hit.t * r.dir + n * BAKE_EPSILON
    mesh := asset_system.meshes[b.scene.instances[hit.instance].mesh]
    albedo := asset_system.material_albedo[mesh.material]
    L = bake_direct(b, p, n)
    for l in 0..<b.layers {
        one: Probe_Layer_Scales
        one[l] = 1
        L[l] = albedo * (L[l] + probe_grid_sample(&b.prev, p, n, one))
    }
    return
}

// Direct light at p facing n, into each light's layer, as scene.slang's frag_main lights it (diffuse only, no 1/π), with one
// shadow ray per light that reaches p. Every light is shadowed here, whatever its `shadow` says.
@(private="file")
bake_direct :: proc(b: ^Bake, p, n: vec3) -> (e: Bake_Layers) {
    for &light, li in b.lights {
        L: vec3
        atten := f32(1)
        dist := max(f32)   // how far the shadow ray looks
        #partial switch EntityLightType(light.type) {
        case .Directional:
            L = -light.direction
        case .Cylinder:
            // Parallel rays along the beam from the disc; the shadow ray runs back to the disc.
            L = -light.direction
            rel    := p - light.position
            along  := linalg.dot(rel, light.direction)
            across := linalg.length(rel - light.direction * along)
            t := clamp((light.beam_radius - across) / max(light.beam_radius - light.beam_inner, 0.0001), 0, 1)
            atten = along > 0 ? bake_falloff(&light, along * along) * t * t : 0
            dist = along
        case:
            to_light := light.position - p
            d2 := max(linalg.dot(to_light, to_light), 1e-8)
            dist = math.sqrt(d2)
            L = to_light / dist
            atten = bake_falloff(&light, d2)
            if EntityLightType(light.type) == .Spot {
                t := clamp((linalg.dot(-L, light.direction) - light.cos_outer) / max(light.cos_inner - light.cos_outer, 0.0001), 0, 1)
                atten *= t * t
            }
        }
        ndl := linalg.dot(n, L)
        if ndl <= 0 || atten <= 0 do continue
        if scene_bvh_any_hit(&b.scene, Ray{origin = p, dir = L}, dist) do continue
        e[b.light_layer[li]] += light.color * (light.intensity * atten * ndl)
    }
    return
}

// scene.slang's light_falloff.
@(private="file")
bake_falloff :: proc(light: ^GPU_Light, d2: f32) -> f32 {
    d := math.sqrt(d2)
    inner, outer := light.inner_radius, light.radius
    switch EntityLightFalloff(light.falloff) {
    case .Linear:
        return 1 - clamp((d - inner) / max(outer - inner, 0.0001), 0, 1)
    case .Smooth:
        return 1 - math.smoothstep(inner, max(outer, inner + 0.0001), d)
    case .Inverse_Square:
        r := d2 / (outer * outer)
        window := clamp(1 - r * r, 0, 1)
        return window * window / max(d2, max(inner * inner, 0.0001))
    }
    return 0
}
