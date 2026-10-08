package blimp

import "core:fmt"
import "core:log"
import "core:strconv"
import "core:strings"
import vmem "core:mem/virtual"
import hm "core:container/handle_map"

World :: struct {
    entities: Entity_Handle_Map,
    render: World_Render,   // GPU draw mirror (transforms/instances/draw-cmds), rebuilt per frame

    title:     string,      // shown in the Worlds window and on its viewport tabs
    save_path: string,      // where scene_save writes; "" ⇒ opened from a kit (can't save back to a glTF)
    source:    string,      // the file it was opened from (scene .level or kit glTF), so it isn't opened twice

    settings: World_Settings,     // the scene file's [world] section
    script:   Lua_World_Script,   // its Lua script's loaded state (lua_world_script.odin) — runtime, never saved
    physics:  Physics_World,      // play worlds: Box3D's copy of the static collision (world_physics.odin) — runtime
    probes:   Probe_Grid,         // baked indirect light (world_probes.odin); loaded from and baked to the level's .probes sidecar, not undoable
    light_group_override: [MAX_LIGHT_GROUPS + 1]Maybe(f32),
    debug_lines: [dynamic]World_Debug_Line,   // drawn by game code (Lua World.debug_line) this tick, in every view of the world   // runtime scales set by Lua or the Lighting menu, over the saved ones; never saved

    // Play mode (world_play.odin): a level points at its running copy, the copy back at its level.
    play_world:  ^World,
    play_source: ^World,
    paused:      bool,   // play worlds: the game doesn't advance
    step:        bool,   // paused play worlds: advance one frame on the next tick (world_step)
    ticks:       bool,   // this frame: the game advances (world_play_tick) — what game systems check
    time:        f64,    // play worlds: game seconds since Play, advanced only on frames that tick (pause and F10 step respected)
    dt:          f32,    // this frame's game seconds: the frame's dt when it ticks, else 0
    anim:        ^Anim_World,   // play worlds: animation state (world_anim.odin) — runtime, nil when not playing
}

// A line game code asked to see (World.debug_line): drawn in every view of its world, the game view too,
// until the world's next tick — so a script redraws what it wants each update, and lines hold while paused.
World_Debug_Line :: struct {
    a, b:  vec3,
    color: vec4,
}

world_debug_line :: proc(w: ^World, a, b: vec3, color: vec4) {
    append(&w.debug_lines, World_Debug_Line{a, b, color})
}

// Per-world settings, saved as the [world] section at the top of the scene file (before the
// entities). Only fields something reads today; sky / atmosphere settings join as those
// systems land — one line each, edited and saved for free (reflection inspector + serializer).
World_Settings :: struct {
    background: [3]f32 `loc:World_Background, widget:linear_color`,   // the viewport clear colour: linear scene light, through exposure and the tonemap like every pixel
    exposure:   f32 `loc:World_Exposure`,   // stops (EV): the HDR scene is scaled by 2^exposure before the tonemap
    fog:        Fog_Settings `loc:World_Fog`,   // distance and height fog, lamp halos
    sky:        Sky_Settings `loc:World_Sky`,   // a panorama behind everything, in place of the background colour
    shading:    ShadingModel `loc:World_Shading`,   // what an entity's shading Default means (entity_shading)
    script:     sbuf256 `loc:World_Script`,   // the world's Lua script (start + update hooks, run while playing), e.g. assets/scripts/castle.lua
    light_groups: Light_Groups `loc:World_Light_Groups`,   // where the switchable light groups start (world_light_groups.odin)
    bake:       Bake_Settings `hidden`,   // saved as bake.* keys; edited in the Bake window (ui_bake.odin), not this one
    anim_fps:   i32 `loc:World_Anim_Fps`,   // poses update this many times a second, PS1-style stepped motion; 0 = every frame (world_anim.odin)
    retro:      Retro_Settings `loc:World_Retro`,   // the PS1 look of views in render mode .Retro
}

// Fog (claude/rendering.md → Fog), in the post signal pass before the tonemap, so it gets exposure, the
// tonemap and the dither like everything else. Laid out as the inspector shows it: what both fogs share, then
// each part under its own switch.
//   shared: one `color`, linear scene light like light colours; `lit` scales it by the probes' light in the air
//           over the level's average (probe_light_mean): the colour as picked where the light is average, warmer
//           and brighter by a lamp, darker in a dark corner, dimming with its light group. No probes: flat.
//   distance (`distance_fog`): PS1-style, geometry fades out between `start` and `end` (metres along the ray), up
//           to `max_opacity`; below 1 far geometry and the sky (a ray that hit nothing, "infinitely" far) show through.
//   height (`height_fog`): exponential ground mist, `density` per metre at `height`, thinning by e every `falloff`
//           metres up. Not capped: looking up it stays finite on its own, thick at the horizon, clear overhead.
//   halos (`halos`): lamp light (point and spot) the air scatters toward the eye, `glow` per metre plus the
//           mist's density, × each light's `halo`. In the lights' colours, not `color`.
// The distance and height fogs multiply into one transmittance.
Fog_Settings :: struct {
    color:        [3]f32 `loc:World_Fog_Color, widget:linear_color`,   // distance and height fog alike
    lit:          f32    `loc:World_Fog_Lit`,       // 0..1: how far the colour follows the baked light around it

    distance_fog: bool   `loc:World_Fog_Distance_On`,
    start:        f32    `loc:World_Fog_Start`,     // clear nearer than this
    end:          f32    `loc:World_Fog_End`,       // max_opacity of fog from here on
    max_opacity:  f32    `loc:World_Fog_Max_Opacity`,   // 0..1: the ramp's top; 1 = fully hides what's past `end`

    height_fog:   bool   `loc:World_Fog_Height_On`,
    height:       f32    `loc:World_Fog_Height`,    // world y where the mist has `density`; denser below, thinner above
    density:      f32    `loc:World_Fog_Density`,   // per metre at `height`
    falloff:      f32    `loc:World_Fog_Falloff`,   // metres up for the density to fall by e

    halos:        bool   `loc:World_Fog_Halos`,
    glow:         f32    `loc:World_Fog_Glow`,      // per metre: haze that scatters lamp light even with no mist
}

// The sky (claude/rendering.md → Sky): an equirectangular panorama (2:1, any loaded PNG) drawn behind the
// scene in place of the background colour. Its texels are sRGB, decoded to linear and × `intensity`: scene light
// like everything else, so exposure, fog and the tonemap apply. No texture: the background colour.
Sky_Settings :: struct {
    texture:   string `loc:World_Sky_Texture, widget:texture`,
    intensity: f32    `loc:World_Sky_Intensity`,   // × the texture's linear colour
    rotation:  f32    `loc:World_Sky_Rotation`,    // degrees about +Y
}

// The retro look (claude/rendering.md → Retro look): what a view in render mode .Retro does, effect by
// effect, each with its switch and its amounts. A view reads the settings of the world it shows (during play the
// play copy). The viewport toolbar's retro toggle turns all of it off for one view (.Clean).
Retro_Settings :: struct {
    low_res:        bool `loc:Retro_Low_Res`,
    lines:          i32  `loc:Retro_Lines`,          // the scene height to aim for: it upscales by the whole number that comes closest
    vertex_snap:    bool `loc:Retro_Vertex_Snap`,
    snap:           f32  `loc:Retro_Snap`,           // the vertex grid, in scene pixels: 1 = whole pixels, more = coarser jitter
    affine:         bool `loc:Retro_Affine`,
    warp:           f32  `loc:Retro_Warp`,           // 0..1: 1 = the full PS1 affine mapping, lower softens it on big polygons
    texel_lighting: bool `loc:Retro_Texel_Lighting`, // light per texel: steps aligned to the colour texture (scene.slang)
    point_sampling: bool `loc:Retro_Point_Sampling`,
    quantize:       bool `loc:Retro_Quantize`,
    color_bits:     i32  `loc:Retro_Color_Bits`,     // per channel (RETRO_COLOR_BITS_MIN..8); the PS1 had 5
    dither:         f32  `loc:Retro_Dither`,         // 0..1, 4x4 Bayer: 0 = plain banding, 1 = full
}

RETRO_COLOR_BITS_MIN :: 2

// The probe bake's inputs (editor_bake.odin, claude/rendering.md → Baker). Read by the baker only: a change
// shows after the next bake. Drawn by hand in the Bake window (ui_bake.odin), not by the reflection inspector.
Bake_Settings :: struct {
    quality:       Bake_Quality,   // a preset sets rays and bounces; editing either makes it Custom
    rays:          i32,    // per probe per pass, on a Fibonacci sphere (BAKE_RAYS_MIN..BAKE_RAYS_MAX)
    bounces:       i32,    // passes (1..BAKE_BOUNCES_MAX)
    sky:           bool,   // the sky lights the probes: a bake ray that escapes the level sees World_Settings.sky's
                           // texture, or else the background colour
    sky_intensity: f32,    // × that sky, for the bake only
    probe_spacing: f32,      // metres between probes, each axis
    bounds:        Bake_Bounds,
    bounds_min:    [3]f32,   // the grid's box when bounds = .Manual
    bounds_max:    [3]f32,
}

Bake_Quality :: enum { Draft, Medium, High, Custom }
Bake_Bounds  :: enum { Auto, Manual }   // Auto: the static geometry's bounds plus one spacing all round

BAKE_QUALITY_PRESETS := [Bake_Quality][2]i32{   // rays, bounces; Custom keeps what's there
    .Draft  = {64, 1},
    .Medium = {256, 3},
    .High   = {1024, 4},
    .Custom = {},
}

WORLD_SETTINGS_DEFAULT :: World_Settings{
    background   = {19.0 / 255, 19.0 / 255, 19.0 / 255},   // linear: a dark grey after the tonemap
    shading      = .Lambert,
    fog          = {color = {0.2, 0.2, 0.2}, start = 20, end = 60, max_opacity = 1, density = 0.1, falloff = 2, glow = 0.05},
    sky          = {intensity = 1},
    bake         = {quality = .Medium, rays = 256, bounces = 3, sky = true,sky_intensity = 1, probe_spacing = 1},
    light_groups = {group_1 = {scale = 1}, group_2 = {scale = 1}, group_3 = {scale = 1}, group_4 = {scale = 1}},
    retro        = {low_res = true, lines = 216, vertex_snap = true, snap = 1, affine = true, warp = 1,
                    point_sampling = true, quantize = true, color_bits = 5, dither = 1},
}

world_init :: proc(world: ^World) {
    world.settings = WORLD_SETTINGS_DEFAULT
    if err := vmem.arena_init_growing(&world.probes.arena); err != nil {
        log.panicf("Failed to init probe arena: %v", err)
    }
}

world_shutdown :: proc(world: ^World) {
    vmem.arena_destroy(&world.probes.arena)
    delete(world.debug_lines)
}

// The one way an entity enters a world — level load, paste, duplicate, kits, Lua: interns its
// asset keys (so they outlive whatever text they were read from, and an asset reload), makes its name
// unique in `world`, and adds it. ok = false if the world is full (MAX_ENTITIES).
world_add :: proc(world: ^World, e: Entity) -> (Entity_Handle, bool) #optional_ok {
    e := e
    e.handle = {}
    asset_intern_keys(e)   // model, sound, any key field the schema adds
    unique := world_unique_name(world, sbuf_str(&e.name))
    if unique != sbuf_str(&e.name) do sbuf_set(&e.name, unique)   // only write when it changed: `unique` may alias e.name
    return hm.add(&world.entities, e)
}

// A new default entity, named and placed (kits, Lua's World.add).
world_add_named :: proc(world: ^World, name: string, model: string, position: vec3 = {0, 0, 0}) -> Entity_Handle {
    e := entity_default()
    sbuf_set(&e.name, name)
    e.model = model
    e.position = position
    return world_add(world, e)
}

// Entity names are unique within a world: world_add goes through this. Returns `name` if no entity in `w` has it yet, otherwise <base>_1, <base>_2, … — the first
// free one — where <base> is `name` minus any existing _<number> suffix, so copying "car_1" gives
// "car_2", not "car_1_1". An empty name becomes "entity". The result fits sbuf64 (the base is
// shortened, on a UTF-8 boundary, to make room for the suffix). Returned string is temp.
world_unique_name :: proc(w: ^World, name: string) -> string {
    name := name
    if name == "" do name = "entity"
    if !world_name_taken(w, name) do return name

    base := name
    if i := strings.last_index_byte(name, '_'); i >= 0 && i + 1 < len(name) {
        all_digits := true
        for c in name[i + 1:] do if c < '0' || c > '9' { all_digits = false; break }
        if all_digits do base = name[:i]
    }

    // One scan for the highest existing base_N, then propose base_(N+1). Probing _1, _2, … instead
    // rescans the world per probe, which is cubic when pasting many copies of one name. The loop
    // still verifies, which covers bases truncated to fit the sbuf (they won't match `base` here).
    max_n := 0
    it := hm.iterator_make(&w.entities)
    for e, _ in hm.iterate(&it) {
        s := sbuf_str(&e.name)
        if len(s) <= len(base) + 1 || s[len(base)] != '_' || !strings.has_prefix(s, base) do continue
        if n, ok := strconv.parse_int(s[len(base) + 1:], 10); ok && n > max_n do max_n = n
    }

    for n := max_n + 1; ; n += 1 {
        suffix := fmt.tprintf("_%d", n)
        keep := min(len(base), cap(sbuf64{}) - len(suffix))
        for keep > 0 && keep < len(base) && (base[keep] & 0xC0) == 0x80 do keep -= 1   // don't split a UTF-8 char
        candidate := fmt.tprintf("%s%s", base[:keep], suffix)
        if !world_name_taken(w, candidate) do return candidate
    }
}

// After an in-place rename (the inspector): if another entity in `w` already has `handle`'s name —
// or the name was cleared — renames it to the next free <base>_N.
world_fix_duplicate_name :: proc(w: ^World, handle: Entity_Handle) {
    e, ok := entity_get(w, handle)
    if !ok do return
    name := sbuf_str(&e.name)
    clash := name == ""
    it := hm.iterator_make(&w.entities)
    for o, h in hm.iterate(&it) do if h != handle && sbuf_str(&o.name) == name { clash = true; break }
    // Safe to pass the result straight to sbuf_set: on a clash world_unique_name never returns `name`
    // itself (it's taken), so it can't alias e.name.
    if clash do sbuf_set(&e.name, world_unique_name(w, name))
}

@(private="file")
world_name_taken :: proc(w: ^World, name: string) -> bool {
    _, taken := world_find(w, name)
    return taken
}

world_remove :: proc(world: ^World, handle: Entity_Handle) {
    hm.remove(&world.entities, handle)
}

world_find :: proc(world: ^World, name: string) -> (Entity_Handle, bool) {
    it := hm.iterator_make(&world.entities)
    for e, h in hm.iterate(&it) {
        if sbuf_str(&e.name) == name do return h, true
    }
    return {}, false
}

// What an entity's shading means in `world`: Default is the level's.
entity_shading :: proc(world: ^World, entity: ^Entity) -> ShadingModel {
    switch entity.shading {
    case .Default: return world.settings.shading
    case .Unlit:   return .Unlit
    case .Gouraud: return .Gouraud
    case .Lambert: return .Lambert
    case .Flat:    return .Flat
    case .Phong:   return .Phong
    }
    return .Lambert
}

// The 8 world-space corners of `e`'s model box (box_corners order); false if it has no model.
entity_world_corners :: proc(e: ^Entity) -> (corners: [8]vec3, ok: bool) {
    model := asset_system.models[e.model] or_return
    lo, hi := model_bounds(model)
    return box_corners(entity_transform(e), lo, hi), true
}

// A copy of entity `h` (everything, the selection flag included) under a unique name.
world_clone :: proc(world: ^World, h: Entity_Handle) -> (copy: Entity_Handle, ok: bool) {
    src := entity_get(world, h) or_return
    return world_add(world, src^)
}
