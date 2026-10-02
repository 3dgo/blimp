package blimp

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:strings"
import "core:path/filepath"
import vmem "core:mem/virtual"

// Baked irradiance probes on a uniform grid (claude/rendering.md → Lighting). The baker (editor_bake.odin)
// fills a world's grid, the level's .probes sidecar stores it, and the scene shader samples it for
// indirect light. A play world reads its level's grid (world_level), it never has its own.

MAX_PROBES     :: 65536
PROBES_EXT     :: ".probes"
PROBES_MAGIC   :: u32(0x424F5250)   // "PROB"
PROBES_VERSION :: u32(3)   // 2: light-group layers; 3: depth maps

// Layer 0 is static (the sky and group-0 lights); then one per light group that has lights at bake time.
MAX_PROBE_LAYERS :: 1 + MAX_LIGHT_GROUPS

// One scale per layer: its light group's (probe_layer_scales). The lit sum is the layers, each times its scale.
Probe_Layer_Scales :: [MAX_PROBE_LAYERS]f32

// One probe: L2 spherical harmonics of irradiance / π, 9 linear RGB coefficients. Divided by π so
// albedo × sh_eval(N) is the bounced light leaving a surface, matching direct light's no-1/π convention
// (claude/rendering.md → Lighting). Mirrors Probe in scene.slang (27 floats + pad: float arrays pack tightly).
Probe_SH :: struct {
    c:    [9]vec3,
    _pad: f32,
}
#assert(size_of(Probe_SH) == 112)

// One probe's view of the geometry around it, for the visibility test (probe_visibility): an octahedral map
// (octahedral_encode) of PROBE_DEPTH_RES² texels, each the mean and mean² of the distance the probe's rays
// travelled near the texel's direction, clamped to PROBE_DEPTH_RANGE spacings (a miss counts as that).
// Geometry only, so one per probe, not per layer. A buried probe's map is all zero, so the test gives it
// next to no weight. Mirrors ProbeDepth in shading.slang (a float array: mean, mean² per texel).
PROBE_DEPTH_RES   :: 8
PROBE_DEPTH_RANGE :: 2.0    // spacings a depth texel can hold
PROBE_NORMAL_BIAS :: 0.2    // spacings a lit point moves off its surface before the test, so the surface can't hide itself
PROBE_MIN_VARIANCE :: 1e-3  // × spacing²: the variance floor, so a flat wall's zero variance doesn't make the test a hard step
Probe_Depth :: struct {
    t: [PROBE_DEPTH_RES * PROBE_DEPTH_RES][2]f32,
}
#assert(size_of(Probe_Depth) == 512)

Probe_Grid :: struct {
    origin:  vec3,         // probe (0, 0, 0), world space
    spacing: f32,          // metres between neighbours, each axis
    dims:    [3]i32,
    layers:      i32,                    // how many layers probes holds
    layer_group: [MAX_PROBE_LAYERS]u8,   // each layer's light group (layer 0: group 0, static)
    probes:  []Probe_SH,   // layers × the grid: layer-major, then x fastest, then y, then z; empty = not baked
    depth:   []Probe_Depth,   // one per probe, laid out like a layer of probes
    atlas:   Image,        // the grid as a picture for the Bake and Resources windows (probe_grid_atlas); not used for lighting
    arena:   vmem.Arena,   // owns probes; freed whole when a new grid replaces them
}

// The .probes file: this header, then layers × dims.x*dims.y*dims.z Probe_SH, then one Probe_Depth per probe.
@(private="file")
Probe_File_Header :: struct {
    magic, version: u32,
    origin:  vec3,
    spacing: f32,
    dims:    [3]i32,
    layers:  i32,
    layer_group: [8]u8,   // the first `layers` are used
}
#assert(MAX_PROBE_LAYERS <= 8)

// Within one layer; layer k's copy is k × probe_count(g) further on.
probe_index :: proc(g: ^Probe_Grid, x, y, z: i32) -> int {
    return int(x + g.dims.x * (y + g.dims.y * z))
}

probe_count :: proc(g: ^Probe_Grid) -> int {
    return int(g.dims.x) * int(g.dims.y) * int(g.dims.z)
}

probe_position :: proc(g: ^Probe_Grid, x, y, z: i32) -> vec3 {
    return g.origin + g.spacing * vec3{f32(x), f32(y), f32(z)}
}

// Replaces the world's grid (CPU side). Its GPU copy follows in world_render_create, or
// world_render_probes_recreate for a world already on screen.
probe_grid_set :: proc(w: ^World, origin: vec3, spacing: f32, dims: [3]i32, layer_group: []u8, probes: []Probe_SH, depth: []Probe_Depth) {
    g := &w.probes
    vmem.arena_free_all(&g.arena)
    g.origin, g.spacing, g.dims = origin, spacing, dims
    g.layers, g.layer_group = i32(len(layer_group)), {}
    copy(g.layer_group[:], layer_group)
    g.probes = make([]Probe_SH, len(probes), vmem.arena_allocator(&g.arena))
    copy(g.probes, probes)
    g.depth = make([]Probe_Depth, len(depth), vmem.arena_allocator(&g.arena))
    copy(g.depth, depth)
    // The atlas shows the groups at their saved scales, without flicker: how the level starts.
    saved: [MAX_LIGHT_GROUPS + 1]f32
    saved[0] = 1
    for k in 1..=MAX_LIGHT_GROUPS do saved[k] = light_group_settings(w, k).scale
    g.atlas = probe_grid_atlas(g, probe_layer_scales(g, saved), math.pow(2, w.settings.exposure), vmem.arena_allocator(&g.arena))
}

// Each layer's scale from every group's (light_group_scales).
probe_layer_scales :: proc(g: ^Probe_Grid, group_scales: [MAX_LIGHT_GROUPS + 1]f32) -> (s: Probe_Layer_Scales) {
    for k in 0..<g.layers do s[k] = group_scales[g.layer_group[k]]
    return
}

// The lit irradiance / pi of probe `index` (probe_index) facing n: its layers, scaled, summed. Not clamped.
probe_eval :: proc(g: ^Probe_Grid, index: int, n: vec3, scales: Probe_Layer_Scales) -> (e: vec3) {
    count := probe_count(g)
    for k in 0..<int(g.layers) do if scales[k] != 0 do e += scales[k] * sh_eval(&g.probes[k * count + index], n)
    return
}

// ============================ Spherical harmonics ============================

// Real SH basis, bands 0–2, at unit direction d.
sh_basis :: proc(d: vec3) -> [9]f32 {
    return {
        0.282095,
        0.488603 * d.y,
        0.488603 * d.z,
        0.488603 * d.x,
        1.092548 * d.x * d.y,
        1.092548 * d.y * d.z,
        0.315392 * (3 * d.z * d.z - 1),
        1.092548 * d.x * d.z,
        0.546274 * (d.x * d.x - d.y * d.y),
    }
}

// Irradiance / π arriving at a surface facing n. Not clamped: L2 rings negative behind a strong
// source, so callers clamp the final sum.
sh_eval :: proc(p: ^Probe_SH, n: vec3) -> (e: vec3) {
    b := sh_basis(n)
    for i in 0..<9 do e += b[i] * p.c[i]
    return
}

// ============================ Visibility ============================

// Octahedral map of the unit sphere onto [-1, 1]²: +Z in the middle, -Z at the corners. Shared with
// shading.slang, so the bake writes the texels the shader reads.
octahedral_encode :: proc(d: vec3) -> [2]f32 {
    p := d.xy / (abs(d.x) + abs(d.y) + abs(d.z))
    if d.z < 0 do p = {(1 - abs(p.y)) * (p.x >= 0 ? 1 : -1), (1 - abs(p.x)) * (p.y >= 0 ? 1 : -1)}
    return p
}

octahedral_decode :: proc(p: [2]f32) -> vec3 {
    n := vec3{p.x, p.y, 1 - abs(p.x) - abs(p.y)}
    if n.z < 0 do n.xy = {(1 - abs(p.y)) * (p.x >= 0 ? 1 : -1), (1 - abs(p.x)) * (p.y >= 0 ? 1 : -1)}
    return linalg.normalize(n)
}

// The direction at the centre of depth texel `t` (x fastest).
probe_depth_texel_dir :: proc(t: int) -> vec3 {
    R :: PROBE_DEPTH_RES
    return octahedral_decode({2 * (f32(t % R) + 0.5) / R - 1, 2 * (f32(t / R) + 0.5) / R - 1})
}

// How much probe `index` (at probe_pos) should count toward lighting the point q, on a surface facing n
// (q already moved off it by PROBE_NORMAL_BIAS): DDGI's two tests. Backface: a probe behind the surface
// counts less, smoothly. Chebyshev: if q is farther from the probe than the geometry its depth map saw
// that way, q is probably hidden from it, by how many standard deviations farther (cubed, to cut what
// leaks through). The trilinear weight is multiplied by this; same as probe_visibility in shading.slang.
probe_visibility :: proc(g: ^Probe_Grid, index: int, probe_pos, q, n: vec3) -> f32 {
    to_probe := probe_pos - q
    d := linalg.length(to_probe)
    if d < 1e-5 do return 1
    to_probe /= d

    wrap := (linalg.dot(to_probe, n) + 1) * 0.5
    w := wrap * wrap + 0.2

    // Bilinear between the four depth texels around the direction from the probe to q.
    R :: PROBE_DEPTH_RES
    uv := octahedral_encode(-to_probe)
    fx := clamp((uv.x * 0.5 + 0.5) * R - 0.5, 0, R - 1)
    fy := clamp((uv.y * 0.5 + 0.5) * R - 0.5, 0, R - 1)
    x0, y0 := int(fx), int(fy)
    x1, y1 := min(x0 + 1, R - 1), min(y0 + 1, R - 1)
    ax, ay := fx - f32(x0), fy - f32(y0)
    t := &g.depth[index].t
    m := linalg.lerp(linalg.lerp(t[y0 * R + x0], t[y0 * R + x1], ax), linalg.lerp(t[y1 * R + x0], t[y1 * R + x1], ax), ay)

    if d > m.x {
        variance := max(m.y - m.x * m.x, PROBE_MIN_VARIANCE * g.spacing * g.spacing)
        cheb := variance / (variance + (d - m.x) * (d - m.x))
        w *= cheb * cheb * cheb
    }
    return max(w, 1e-6)   // never quite zero, so the weights always renormalize
}

// Trilinear between the 8 probes around p, evaluated facing n, layers × `scales`, each corner weighted by
// its visibility (probe_visibility) and the weights renormalized. Clamped to the grid outside it. Zero when
// not baked. The scene shader does the same (shading.slang, probe_irradiance).
probe_grid_sample :: proc(g: ^Probe_Grid, p, n: vec3, scales: Probe_Layer_Scales) -> vec3 {
    if len(g.probes) == 0 do return {}
    q := p + n * (PROBE_NORMAL_BIAS * g.spacing)
    u := (q - g.origin) / g.spacing
    i0, i1: [3]i32
    f: vec3
    for a in 0..<3 {
        ua := clamp(u[a], 0, f32(g.dims[a] - 1))
        i0[a] = min(i32(ua), g.dims[a] - 1)
        i1[a] = min(i0[a] + 1, g.dims[a] - 1)
        f[a]  = ua - f32(i0[a])
    }
    e: vec3
    total: f32
    for c in 0..<8 {
        x := (c & 1) != 0 ? i1.x : i0.x
        y := (c & 2) != 0 ? i1.y : i0.y
        z := (c & 4) != 0 ? i1.z : i0.z
        wt := ((c & 1) != 0 ? f.x : 1 - f.x) * ((c & 2) != 0 ? f.y : 1 - f.y) * ((c & 4) != 0 ? f.z : 1 - f.z)
        if wt == 0 do continue
        index := probe_index(g, x, y, z)
        if len(g.depth) > 0 do wt *= probe_visibility(g, index, probe_position(g, x, y, z), q, n)
        e += wt * probe_eval(g, index, n, scales)
        total += wt
    }
    if total > 0 do e /= total
    return {max(e.x, 0), max(e.y, 0), max(e.z, 0)}
}

// ============================ Sidecar file ============================

// A level's probes live beside it: assets/scenes/a.level → assets/scenes/a.probes.
probes_path :: proc(level_path: string, allocator := context.temp_allocator) -> string {
    return strings.concatenate({strings.trim_suffix(level_path, filepath.ext(level_path)), PROBES_EXT}, allocator)
}

probe_grid_save :: proc(g: ^Probe_Grid, path: string) -> bool {
    h := Probe_File_Header{magic = PROBES_MAGIC, version = PROBES_VERSION, origin = g.origin, spacing = g.spacing, dims = g.dims, layers = g.layers}
    copy(h.layer_group[:], g.layer_group[:g.layers])
    sh_size := len(g.probes) * size_of(Probe_SH)
    data := make([]byte, size_of(h) + sh_size + len(g.depth) * size_of(Probe_Depth), context.temp_allocator)
    mem.copy(&data[0], &h, size_of(h))
    if len(g.probes) > 0 do mem.copy(&data[size_of(h)], raw_data(g.probes), sh_size)
    if len(g.depth) > 0 do mem.copy(&data[size_of(h) + sh_size], raw_data(g.depth), len(g.depth) * size_of(Probe_Depth))
    if err := os.write_entire_file(path, data); err != nil {
        log.errorf("Failed to write probes '%v': %v", path, err)
        return false
    }
    return true
}

// Loads `path` into w's grid. A missing file is fine (not baked yet); a malformed one is logged and skipped.
probe_grid_load :: proc(w: ^World, path: string) {
    if !os.exists(path) do return
    data, err := os.read_entire_file(path, context.temp_allocator)
    if err != nil {
        log.errorf("Failed to read probes '%v': %v", path, err)
        return
    }
    h: Probe_File_Header
    if len(data) < size_of(h) {
        log.errorf("Probes '%v': truncated header", path)
        return
    }
    mem.copy(&h, &data[0], size_of(h))
    grid := int(h.dims.x) * int(h.dims.y) * int(h.dims.z)
    count := grid * int(h.layers)
    switch {
    case h.magic != PROBES_MAGIC:     log.errorf("Probes '%v': not a probes file", path); return
    case h.version != PROBES_VERSION: log.errorf("Probes '%v': version %v, expected %v (rebake)", path, h.version, PROBES_VERSION); return
    case h.layers < 1 || h.layers > MAX_PROBE_LAYERS: log.errorf("Probes '%v': %v layers", path, h.layers); return
    case grid <= 0 || grid > MAX_PROBES || len(data) != size_of(h) + count * size_of(Probe_SH) + grid * size_of(Probe_Depth):
        log.errorf("Probes '%v': size doesn't match its %v grid", path, h.dims); return
    }
    probes := ([^]Probe_SH)(raw_data(data[size_of(h):]))[:count]
    depth := ([^]Probe_Depth)(raw_data(data[size_of(h) + count * size_of(Probe_SH):]))[:grid]
    probe_grid_set(w, h.origin, h.spacing, h.dims, h.layer_group[:h.layers], probes, depth)
    log.infof("Loaded probes '%v' (%v × %v × %v, %v layers)", path, h.dims.x, h.dims.y, h.dims.z, h.layers)
}

// ============================ Debug view ============================

PROBE_DEBUG_SPOKE :: 0.12   // fraction of the spacing each spoke reaches

// Each probe as six short spokes along ±X/±Y/±Z, coloured by the irradiance a surface facing that
// way would get with its layers × `scales`, times `exposure` (the world's 2^EV) and clamped, so it reads
// like the lit scene.
probe_grid_debug_lines :: proc(g: ^Probe_Grid, scales: Probe_Layer_Scales, exposure: f32) {
    dirs := [6]vec3{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
    len_ := g.spacing * PROBE_DEBUG_SPOKE
    for z in 0..<g.dims.z do for y in 0..<g.dims.y do for x in 0..<g.dims.x {
        p := probe_position(g, x, y, z)
        i := probe_index(g, x, y, z)
        for d in dirs {
            e := exposure * probe_eval(g, i, d, scales)
            c := vec4{linear_to_srgb(clamp(e.x, 0, 1)), linear_to_srgb(clamp(e.y, 0, 1)), linear_to_srgb(clamp(e.z, 0, 1)), 1}
            debug_line(p, p + d * len_, c)
        }
    }
}

// ============================ Atlas ============================

PROBE_ATLAS_TILE :: 8          // pixels each way per probe
PROBE_ATLAS_GAP  :: 2          // pixels between layer blocks
PROBE_ATLAS_MAX  :: 16384      // D3D12's 2D texture limit; a bigger atlas isn't made

// The grid as a picture, so you can see what was baked: each probe a PROBE_ATLAS_TILE² octahedral tile of
// the irradiance it gives a surface facing each way (centre up, +Y; edges the horizon; corners down),
// its layers × `scales`, × exposure, clamped, sRGB bytes. One block per layer of probes (y), seen from above with +X right and
// +Z up; blocks run left to right from the bottom layer and wrap into a near-square. Empty when too big.
probe_grid_atlas :: proc(g: ^Probe_Grid, scales: Probe_Layer_Scales, exposure: f32, allocator := context.allocator) -> Image {
    T :: PROBE_ATLAS_TILE
    bw, bh := int(g.dims.x) * T, int(g.dims.z) * T
    cols := int(math.ceil(math.sqrt(f32(g.dims.y))))
    rows := (int(g.dims.y) + cols - 1) / cols
    width, height := cols * bw + (cols - 1) * PROBE_ATLAS_GAP, rows * bh + (rows - 1) * PROBE_ATLAS_GAP
    if width > PROBE_ATLAS_MAX || height > PROBE_ATLAS_MAX do return {}

    img := Image{width = u32(width), height = u32(height), format = .RGBA8, pixels = make([]byte, width * height * 4, allocator)}
    for p in 0..<width * height do copy(img.pixels[4 * p:][:4], []byte{24, 24, 24, 255})   // the gaps

    // Octahedral decode of each tile pixel centre, once.
    basis: [T * T][9]f32
    for j in 0..<T do for i in 0..<T {
        u := 2 * (f32(i) + 0.5) / T - 1
        v := 2 * (f32(j) + 0.5) / T - 1
        n := vec3{u, v, 1 - abs(u) - abs(v)}
        if n.z < 0 do n.xy = {(1 - abs(v)) * math.sign(u), (1 - abs(u)) * math.sign(v)}
        basis[j * T + i] = sh_basis(linalg.normalize(vec3{n.x, n.z, -n.y}))   // tile centre → +Y, image up → +Z
    }

    for y in 0..<g.dims.y do for z in 0..<g.dims.z do for x in 0..<g.dims.x {
        // The probe's layers folded into one set of coefficients first, so each pixel is one 9-term sum.
        sh: Probe_SH
        for l in 0..<int(g.layers) do for c in 0..<9 do sh.c[c] += scales[l] * g.probes[l * probe_count(g) + probe_index(g, x, y, z)].c[c]
        ox := (int(y) % cols) * (bw + PROBE_ATLAS_GAP) + int(x) * T
        oy := (int(y) / cols) * (bh + PROBE_ATLAS_GAP) + int(g.dims.z - 1 - z) * T
        for k in 0..<T * T {
            e: vec3
            for c in 0..<9 do e += basis[k][c] * sh.c[c]
            px := img.pixels[4 * ((oy + k / T) * width + ox + k % T):][:3]
            for a in 0..<3 do px[a] = u8(linear_to_srgb(clamp(exposure * e[a], 0, 1)) * 255 + 0.5)
        }
    }
    return img
}
