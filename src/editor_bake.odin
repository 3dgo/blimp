package blimp

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:time"
import hm "core:container/handle_map"

// The probe baker (claude/rendering.md → Lighting, Baker). A CPU ray tracer over the level's static
// geometry (a Scene_BVH of the entities that pass entity_bakes) fills a uniform grid of L2 SH irradiance
// probes (world_probes.odin). Probes hold indirect light only — sky and bounces. Direct light stays
// realtime, so each light reaches a probe only off a surface it lit.
//
// Pass k: every probe casts `rays` rays. A miss sees the sky. A hit on a front face sends back
// albedo × (direct light there + pass k-1's grid sampled there), so `bounces` passes are that many
// bounces. A back-face hit means the probe sees the inside of something; it sends back black.
// Passes run probes in parallel (parallel_for); each probe writes only its own slot. Rays, bounces and
// what goes in come from World_Settings.bake.

BAKE_RAYS_MIN    :: 16     // rays per probe per pass, on a Fibonacci sphere: the same set for every probe, so bakes repeat exactly
BAKE_RAYS_MAX    :: 4096
BAKE_BOUNCES_MAX :: 8
BAKE_EPSILON     :: 1e-3   // offset off a hit surface (metres) for its shadow rays and grid lookup

// A probe whose rays mostly hit back faces is inside geometry: its depth map is left all zero, so the
// visibility test (probe_visibility) gives it next to no weight anywhere.
BAKE_BURIED_FRACTION :: 0.25

// How tightly a depth texel gathers the rays near its direction: weight = max(0, cos)^this (DDGI's 50).
BAKE_DEPTH_SHARPNESS :: 50

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
    tint:   []vec3,               // per scene instance: its entity's entity_tint, × the material albedo
    lights: []GPU_Light,
    light_layer: []u8,            // each light's probe layer (its group's; layer 0 for group 0)
    light_shadow: []bool,         // each light's `shadow`: its shadow ray is cast
    layers: int,
    sky:    vec3,                 // linear radiance of a miss (layer 0): the background colour × sky_intensity
    sky_table: []vec3,            // or, with a sky texture, the miss radiance by direction (bake_sky_table); nil = sky
    sky_turn:  f32,               // the sky's rotation, turns
    dirs:   []vec3,               // the rays, the same for every probe
    basis:  [][9]f32,             // sh_basis(dirs[k])
    prev:   Probe_Grid,           // the previous pass (all zero on the first); only origin..probes are used
    out:    []Probe_SH,           // this pass, laid out like prev.probes
    back:   []u32,                // back-face hits per probe (pass 0)
    pass:   int,
    depth:  []Probe_Depth,        // filled by pass 0, then prev.depth, so later passes' grid lookups test visibility
    depth_weight: []f32,          // texel × ray: max(0, dot(texel direction, ray))^BAKE_DEPTH_SHARPNESS, row per texel
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
    set := &w.settings.bake
    b: Bake

    b.scene = bake_scene_bvh(w)
    stats.instances = len(b.scene.instances)
    b.tint = make([]vec3, len(b.scene.instances), context.temp_allocator)
    for inst, i in b.scene.instances {
        b.tint[i] = 1
        if e, found := entity_get(w, inst.entity); found do b.tint[i] = entity_tint(e)
    }
    if len(b.scene.nodes) == 0 {
        log.errorf("Bake '%v': no static geometry (entities need Static, Cast Indirect and a model)", w.title)
        return
    }

    // Lights, and a layer for every group that has one: layer 0 first, then the groups in order.
    lights := make([dynamic]GPU_Light, 0, MAX_LIGHTS, context.temp_allocator)
    groups := make([dynamic]int, 0, MAX_LIGHTS, context.temp_allocator)
    shadows := make([dynamic]bool, 0, MAX_LIGHTS, context.temp_allocator)
    has_group: [MAX_LIGHT_GROUPS + 1]bool
    it := hm.iterator_make(&w.entities)
    for e, _ in hm.iterate(&it) {
        if !entity_bakes(e) || e.light_type == .None || len(lights) == MAX_LIGHTS do continue
        light := entity_gpu_light(e)   // at its own intensity: the group scale is applied at runtime
        light.intensity *= e.indirect
        append(&lights, light)
        append(&groups, entity_light_group(e))
        append(&shadows, e.shadow)
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
    b.light_shadow = shadows[:]
    b.light_layer = make([]u8, len(lights), context.temp_allocator)
    for g, i in groups do b.light_layer[i] = group_layer[g]
    stats.lights, stats.layers = len(lights), b.layers
    if set.sky {
        // The sky the views show lights the probes: the sky texture, or else the background colour.
        b.sky = w.settings.background * set.sky_intensity
        if image, found := render_sky_image(w.settings.sky); found {
            sky := w.settings.sky
            b.sky_table = bake_sky_table(asset_system.images[image], max(sky.intensity, 0) * set.sky_intensity)
            b.sky_turn  = sky.rotation / 360
        }
    }

    // The grid covers the geometry's bounds plus one spacing all round, or the manual box.
    spacing := max(set.probe_spacing, 0.05)
    lo := b.scene.nodes[0].min - spacing
    hi := b.scene.nodes[0].max + spacing
    if set.bounds == .Manual {
        lo, hi = set.bounds_min, set.bounds_max
        if hi.x <= lo.x || hi.y <= lo.y || hi.z <= lo.z {
            log.errorf("Bake '%v': the manual grid box is empty (max must be above min on every axis)", w.title)
            return
        }
    }
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
    rays := int(clamp(set.rays, BAKE_RAYS_MIN, BAKE_RAYS_MAX))
    bounces := int(clamp(set.bounces, 1, BAKE_BOUNCES_MAX))
    b.dirs  = make([]vec3, rays, context.temp_allocator)
    b.basis = make([][9]f32, rays, context.temp_allocator)
    for k in 0..<rays {
        z := 1 - (2 * f32(k) + 1) / f32(rays)
        r := math.sqrt(1 - z * z)
        phi := f32(k) * GOLDEN_ANGLE
        b.dirs[k] = {r * math.cos(phi), r * math.sin(phi), z}
        b.basis[k] = sh_basis(b.dirs[k])
    }

    b.prev = Probe_Grid{origin = lo, spacing = spacing, dims = dims, layers = i32(b.layers), layer_group = layer_group,
        probes = make([]Probe_SH, count * b.layers, context.temp_allocator)}
    b.out  = make([]Probe_SH, count * b.layers, context.temp_allocator)
    b.back = make([]u32, count, context.temp_allocator)
    b.depth = make([]Probe_Depth, count, context.temp_allocator)
    TEXELS :: PROBE_DEPTH_RES * PROBE_DEPTH_RES
    b.depth_weight = make([]f32, TEXELS * rays, context.temp_allocator)
    for t in 0..<TEXELS {
        td := probe_depth_texel_dir(t)
        for dir, k in b.dirs do b.depth_weight[t * rays + k] = math.pow(max(linalg.dot(td, dir), 0), BAKE_DEPTH_SHARPNESS)
    }

    for pass in 0..<bounces {
        b.pass = pass
        stats.threads = parallel_for(count, &b, bake_probe)
        b.prev.probes, b.out = b.out, b.prev.probes   // this pass is the next one's light source
        b.prev.depth = b.depth                        // and from pass 1 on, its lookups test visibility
        log.infof("Bake '%v': pass %v/%v done (%.1f s)", w.title, pass + 1, bounces, time.duration_seconds(time.tick_since(start)))
    }
    stats.rays = count * rays * bounces

    total_back := 0
    for n in b.back {
        total_back += int(n)
        if f32(n) > BAKE_BURIED_FRACTION * f32(rays) do stats.buried += 1
    }
    stats.backface = f32(total_back) / f32(count * rays)

    probe_grid_set(w, lo, spacing, dims, layer_group[:b.layers], b.prev.probes, b.depth)
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

// The box an Auto bake would fill: the static geometry's bounds plus one spacing all round. Builds a
// scene BVH in scratch, so it's for a button press, not every frame.
bake_auto_bounds :: proc(w: ^World) -> (lo, hi: vec3, ok: bool) {
    scene := bake_scene_bvh(w)
    if len(scene.nodes) == 0 do return
    spacing := max(w.settings.bake.probe_spacing, 0.05)
    return scene.nodes[0].min - spacing, scene.nodes[0].max + spacing, true
}

// One probe, one pass, every layer (parallel_for body: no allocation, no logging). Pass 0 also records
// the probe's depth map and back-face count: geometry, the same every pass.
@(private="file")
bake_probe :: proc(data: rawptr, i: int) {
    b := (^Bake)(data)
    g := &b.prev
    x := i32(i) % g.dims.x
    y := (i32(i) / g.dims.x) % g.dims.y
    z := i32(i) / (g.dims.x * g.dims.y)
    p := probe_position(g, x, y, z)

    TEXELS :: PROBE_DEPTH_RES * PROBE_DEPTH_RES
    sh: [MAX_PROBE_LAYERS][9]vec3
    back: u32
    depth: [TEXELS][3]f32   // per texel: Σw, Σw·d, Σw·d²
    max_d := PROBE_DEPTH_RANGE * g.spacing
    rays := len(b.dirs)
    for dir, k in b.dirs {
        t: f32
        L := bake_radiance(b, Ray{origin = p, dir = dir}, &back, &t)
        for l in 0..<b.layers do for c in 0..<9 do sh[l][c] += L[l] * b.basis[k][c]
        if b.pass == 0 {
            d := min(t, max_d)
            for j in 0..<TEXELS {
                w := b.depth_weight[j * rays + k]
                if w > 0 do depth[j] += {w, w * d, w * d * d}
            }
        }
    }
    if b.pass == 0 {
        b.back[i] = back
        b.depth[i] = {}   // buried: all zero
        if f32(back) <= BAKE_BURIED_FRACTION * f32(rays) {
            for j in 0..<TEXELS do if depth[j][0] > 0 do b.depth[i].t[j] = {depth[j][1] / depth[j][0], depth[j][2] / depth[j][0]}
        }
    }
    // Monte Carlo over the sphere (× 4π / N), then irradiance = the cosine lobe convolved (bands × π,
    // 2π/3, π/4), stored / π: bands × 1, 2/3, 1/4.
    BAND := [9]f32{1, 2.0/3, 2.0/3, 2.0/3, 0.25, 0.25, 0.25, 0.25, 0.25}
    count := probe_count(g)
    for l in 0..<b.layers do for c in 0..<9 do b.out[l * count + i].c[c] = sh[l][c] * (4 * math.PI / f32(len(b.dirs))) * BAND[c]
}

// Radiance arriving along r, per layer, and how far the ray went (t; max(f32) for a miss). One trace
// serves every layer; only what lights the hit differs.
@(private="file")
bake_radiance :: proc(b: ^Bake, r: Ray, back: ^u32, t: ^f32) -> (L: Bake_Layers) {
    hit, ok := scene_bvh_closest_hit(&b.scene, r)
    if !ok {
        t^ = max(f32)
        L[0] = bake_sky(b, r.dir)
        return
    }
    t^ = hit.t

    // Front faces are clockwise seen from the front (left-handed, Y-up): cross(v1 − v0, v2 − v0) faces out.
    tri := scene_hit_triangle(&b.scene, hit)
    n := linalg.normalize(linalg.cross(tri[1] - tri[0], tri[2] - tri[0]))
    if linalg.dot(n, r.dir) >= 0 {
        back^ += 1
        return
    }

    p := r.origin + hit.t * r.dir + n * BAKE_EPSILON
    mesh := asset_system.meshes[b.scene.instances[hit.instance].mesh]
    albedo := asset_system.material_albedo[mesh.material] * b.tint[hit.instance]
    L = bake_direct(b, p, n)
    for l in 0..<b.layers {
        one: Probe_Layer_Scales
        one[l] = 1
        L[l] = albedo * (L[l] + probe_grid_sample(&b.prev, p, n, one))
    }
    return
}

// The sky texture for the bake: box-filtered down to SKY_TABLE_W × SKY_TABLE_H cells of linear radiance. The
// probes hold only low-frequency light, and a few hundred rays per probe sampling the full texture would only add
// noise.
SKY_TABLE_W :: 32
SKY_TABLE_H :: 16

@(private="file")
bake_sky_table :: proc(img: Image, scale: f32) -> []vec3 {
    lut: [256]f32   // byte → linear
    for i in 0..<256 do lut[i] = img.format == .RGBA8_SRGB ? srgb_to_linear(f32(i) / 255) : f32(i) / 255
    table := make([]vec3, SKY_TABLE_W * SKY_TABLE_H, context.temp_allocator)
    count := make([]f32, len(table), context.temp_allocator)
    w, h := int(img.width), int(img.height)
    for y in 0..<h do for x in 0..<w {
        px := img.pixels[4 * (y * w + x):][:3]
        cell := (y * SKY_TABLE_H / h) * SKY_TABLE_W + x * SKY_TABLE_W / w
        table[cell] += {lut[px[0]], lut[px[1]], lut[px[2]]}
        count[cell] += 1
    }
    for &c, i in table do c *= scale / max(count[i], 1)
    return table
}

// A miss's radiance along unit direction d: the sky table's cell, mapped like sky.slang, or the sky colour.
@(private="file")
bake_sky :: proc(b: ^Bake, d: vec3) -> vec3 {
    if b.sky_table == nil do return b.sky
    u := math.atan2(d.x, d.z) / (2 * math.PI) + 0.5 - b.sky_turn
    v := math.acos(clamp(d.y, -1, 1)) / math.PI
    x := clamp(int((u - math.floor(u)) * SKY_TABLE_W), 0, SKY_TABLE_W - 1)
    y := clamp(int(v * SKY_TABLE_H), 0, SKY_TABLE_H - 1)
    return b.sky_table[y * SKY_TABLE_W + x]
}

// Direct light at p facing n, into each light's layer, as scene.slang's frag_main lights it (diffuse only, no 1/π), with one
// shadow ray per light that reaches p, for the lights that cast shadows (`shadow`), as on screen.
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
        if b.light_shadow[li] && scene_bvh_any_hit(&b.scene, Ray{origin = p, dir = L}, dist) do continue
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

// What bake rays hit: every mesh of every entity that takes part in the bake (entity_bakes), as a temp
// Scene_BVH.
@(private="file")
bake_scene_bvh :: proc(w: ^World) -> Scene_BVH {
    instances := make([dynamic]BVH_Instance, 0, MAX_MESH_INSTANCES, context.temp_allocator)
    it := hm.iterator_make(&w.entities)
    for e, h in hm.iterate(&it) {
        if !entity_bakes(e) do continue
        model := asset_system.models[e.model] or_continue
        M := entity_transform(e)
        for mesh in model.meshes {
            if len(instances) == MAX_MESH_INSTANCES do break
            append(&instances, BVH_Instance{to_world = M, mesh = mesh, entity = h})
        }
    }
    return scene_bvh_build(instances[:], context.temp_allocator)
}
