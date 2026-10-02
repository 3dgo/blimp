package blimp

import "core:fmt"
import "core:log"
import "core:strconv"
import "core:strings"
import vmem "core:mem/virtual"
import hm "core:container/handle_map"

World :: struct {
    entities: Entity_Handle_Map,
    arena: vmem.Arena,
    render: World_Render,   // GPU draw mirror (transforms/instances/draw-cmds), rebuilt per frame

    active:    Entity_Handle,   // the selected entity the inspector shows and the gizmo pivots on (editor_selection.odin)
    select_anchor: Entity_Handle,   // entity list: where a Shift+click range starts (the last plain or Ctrl click)
    title:     string,      // shown in the Worlds window and on its viewport tabs
    save_path: string,      // where scene_save writes; "" ⇒ opened from a kit (can't save back to a glTF)
    source:    string,      // the file it was opened from (scene .level or kit glTF), so it isn't opened twice

    // Unsaved-changes tracking. Every edit goes through undo_push, which gives the world a fresh
    // state id; undo/redo restore the id along with the snapshot. So the world is dirty exactly when
    // its state isn't the one last saved — undoing back to the saved state makes it clean again.
    state_id:       u64,
    saved_state_id: u64,

    settings: World_Settings,     // the scene file's [world] section
    script:   Lua_World_Script,   // its Lua script's loaded state (lua_world_script.odin) — runtime, never saved
    physics:  Physics_World,      // play worlds: Box3D's copy of the static collision (world_physics.odin) — runtime
    probes:   Probe_Grid,         // baked indirect light (render_probes.odin); loaded from and baked to the level's .probes sidecar, not undoable
    light_group_override: [MAX_LIGHT_GROUPS + 1]Maybe(f32),   // runtime scales set by Lua or the Lighting menu, over the saved ones; never saved

    // Play mode (world_play.odin): a level points at its running copy, the copy back at its level.
    play_world:  ^World,
    play_source: ^World,
    paused:      bool,   // play worlds: the game doesn't advance
    step:        bool,   // paused play worlds: advance one frame on the next tick (world_step)
    ticks:       bool,   // this frame: the game advances (world_play_tick) — what game systems check
    time:        f64,    // play worlds: game seconds since Play, advanced only on frames that tick (pause and F10 step respected)
}

// Per-world settings, saved as the [world] section at the top of the scene file (before the
// entities). Only fields something reads today; sky / atmosphere settings join as those
// systems land — one line each, edited and saved for free (reflection inspector + serializer).
World_Settings :: struct {
    background: [3]f32 `loc:World_Background, widget:color`,   // the viewport clear colour: display-space (sRGB), shown as picked, not tonemapped
    exposure:   f32 `loc:World_Exposure`,   // stops (EV): the HDR scene is scaled by 2^exposure before the tonemap
    shading:    ShadingModel `loc:World_Shading`,   // what an entity's shading Default means (entity_shading)
    script:     sbuf256 `loc:World_Script`,   // the world's Lua script (init + update), e.g. assets/scripts/level.lua
    light_groups: Light_Groups `loc:World_Light_Groups`,   // where the switchable light groups start (world_light_groups.odin)
    bake:       Bake_Settings `hidden`,   // saved as bake.* keys; edited in the Bake window (ui_bake.odin), not this one
    retro:      Retro_Settings `hidden`,  // saved as retro.* keys; edited in the Retro Look window (ui_retro.odin)
}

// The retro look (claude/rendering.md → Retro look): what a view in render mode .Retro does, effect by
// effect. Views read their level's settings, so edits show live, in play too. Each effect has its switch
// and its amounts; a group's `on` switches all of its effects. Drawn by hand in the Retro Look window.
Retro_Settings :: struct {
    ps1: Retro_PS1,
    crt: Retro_CRT,
}

Retro_PS1 :: struct {
    on:             bool,
    low_res:        bool,
    lines:          i32,    // the scene height to aim for: it upscales by the whole number that comes closest
    vertex_snap:    bool,
    snap:           f32,    // the vertex grid, in scene pixels: 1 = whole pixels, more = coarser jitter
    affine:         bool,
    warp:           f32,    // 1 = the full PS1 affine mapping, lower softens it on big polygons
    point_sampling: bool,
    quantize:       bool,
    color_bits:     i32,    // per channel (RETRO_COLOR_BITS_MIN..8); the PS1 had 5
    dither:         f32,    // 4x4 Bayer dither: 0 = plain banding, 1 = full
}

// A composite TV showing the PS1's signal. Distances are in scene pixels (lines, vertically).
Retro_CRT :: struct {
    on:             bool,
    composite:      bool,
    luma_blur:      f32,    // horizontal blur of brightness (sigma); this is what melts the dither
    chroma_blur:    f32,    // of colour: composite chroma is far narrower, so colour bleeds sideways
    scanlines:      bool,
    scanline_strength: f32, // 0 = flat lines, 1 = the full beam profile
    beam_dark:      f32,    // beam width (sigma) of a black line: thin, so dark lines part into gaps
    beam_bright:    f32,    // and of a white one: fat, so bright lines merge
    mask:           bool,
    mask_strength:  f32,    // aperture grille depth: the lit stripe is 1 + 2x, the other two 1 - x
    bloom:          bool,
    bloom_strength: f32,    // the glass's glow, added on top
    bloom_radius:   f32,    // sigma
    gamma:          f32,    // the tube's: 2.2 = neutral, higher = deeper shadows
    brightness:     f32,    // × the light, to win back what the mask and scanlines cost
}

RETRO_COLOR_BITS_MIN :: 2

RETRO_SETTINGS_DEFAULT :: Retro_Settings{
    ps1 = {on = true, low_res = true, lines = 216, vertex_snap = true, snap = 1, affine = true, warp = 1,
           point_sampling = true, quantize = true, color_bits = 5, dither = 1},
    crt = {on = false, composite = true, luma_blur = 0.25, chroma_blur = 0.8,
           scanlines = true, scanline_strength = 0.5, beam_dark = 0.32, beam_bright = 0.6,
           mask = true, mask_strength = 0.1, bloom = true, bloom_strength = 0.06, bloom_radius = 3,
           gamma = 2.3, brightness = 1},
}

// The probe bake's inputs (editor_bake.odin, claude/rendering.md → Baker). Read by the baker only: a change
// shows after the next bake. Drawn by hand in the Bake window (ui_bake.odin), not by the reflection inspector.
Bake_Settings :: struct {
    quality:       Bake_Quality,   // a preset sets rays and bounces; editing either makes it Custom
    rays:          i32,    // per probe per pass, on a Fibonacci sphere (BAKE_RAYS_MIN..BAKE_RAYS_MAX)
    bounces:       i32,    // passes (1..BAKE_BOUNCES_MAX)
    sky:           bool,   // the sky lights the probes
    sky_color:     [3]f32,   // radiance of a bake ray that escapes the level (linear), × sky_intensity
    sky_intensity: f32,
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
    background   = {19.0 / 255, 19.0 / 255, 19.0 / 255},   // #131313
    shading      = .Lambert,
    bake         = {quality = .Medium, rays = 256, bounces = 3, sky = true,sky_intensity = 1, probe_spacing = 1},
    light_groups = {group_1 = {scale = 1}, group_2 = {scale = 1}, group_3 = {scale = 1}, group_4 = {scale = 1}},
    retro        = RETRO_SETTINGS_DEFAULT,
}
// Lua's target until world scripts exist (the @(lua) world/entity procs pin to it). Not shown by the
// editor — worlds the user works on are opened from the Worlds window (world_registry.odin).
game_world: World

world_init :: proc(world: ^World) {
    world.settings = WORLD_SETTINGS_DEFAULT
    if err := vmem.arena_init_growing(&world.arena); err != nil {
        log.panicf("Failed to init world arena: %v", err)
    }
    if err := vmem.arena_init_growing(&world.probes.arena); err != nil {
        log.panicf("Failed to init probe arena: %v", err)
    }
}

world_shutdown :: proc(world: ^World) {
    vmem.arena_destroy(&world.arena)
    vmem.arena_destroy(&world.probes.arena)
}

world_clear :: proc(world: ^World) {
    hm.clear(&world.entities)
    vmem.arena_free_all(&world.arena)
}

world_add :: proc(world: ^World, name: string, model: string, position: vec3 = {0, 0, 0}) -> Entity_Handle {
    e: Entity
    entity_apply_defaults(&e)   // schema defaults (rotation identity, scale 1, user fields…)
    sbuf_set(&e.name, world_unique_name(world, name))   // explicit args override the defaults
    e.model = asset_model_key(model)
    e.position = position
    return hm.add(&world.entities, e)
}

// Entity names are unique within a world: every add (world_add, scene load, paste) goes through
// this. Returns `name` if no entity in `w` has it yet, otherwise <base>_1, <base>_2, … — the first
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

// Renames `e` (not yet added to `w`) to a name unique in `w`, if needed.
entity_make_name_unique :: proc(w: ^World, e: ^Entity) {
    unique := world_unique_name(w, sbuf_str(&e.name))
    if unique != sbuf_str(&e.name) do sbuf_set(&e.name, unique)   // only write when it changed: `unique` may alias e.name
}

@(private="file")
world_name_taken :: proc(w: ^World, name: string) -> bool {
    it := hm.iterator_make(&w.entities)
    for e, _ in hm.iterate(&it) do if sbuf_str(&e.name) == name do return true
    return false
}

world_remove :: proc(world: ^World, handle: Entity_Handle) {
    selection_set(world, handle, false)   // moves `active` off it first
    hm.remove(&world.entities, handle)
}

world_find :: proc(world: ^World, name: string) -> (Entity_Handle, bool) {
    it := hm.iterator_make(&world.entities)
    for e, h in hm.iterate(&it) {
        if sbuf_str(&e.name) == name do return h, true
    }
    return {}, false
}

@(lua=add, table=World, lua_zh="添加")
world_add_lua :: proc(name: string, model: string, position: vec3 = {0, 0, 0}) -> Entity_Handle {
    return world_add(lua_world(), name, model, position)
}

@(lua=remove, table=World, lua_zh="移除")
world_remove_lua :: proc(handle: Entity_Handle) { world_remove(lua_world(), handle) }

@(lua=find, table=World, lua_zh="查找")
world_find_lua :: proc(name: string) -> (Entity_Handle, bool) { return world_find(lua_world(), name) }

// Game seconds since Play (World.time): animate from this, not from a clock kept in Lua. Stops while paused.
@(lua=time, table=World, lua_zh="时间")
world_time_lua :: proc() -> f64 { return lua_world().time }
@(private="file") world_state_counter: u64   // state ids are unique across all worlds

// The world is about to change (called by undo_push): it gets a state id it has never had.
world_new_state :: proc(w: ^World) {
    world_state_counter += 1
    w.state_id = world_state_counter
}

// Unsaved changes. Kits can't be saved, so they're never dirty (closing one never prompts); nor can
// play worlds (no save_path).
world_dirty :: proc(w: ^World) -> bool {
    return w.save_path != "" && w.state_id != w.saved_state_id
}

// A copy of entity `h` (everything, the selection flag included) under a unique name.
world_clone :: proc(world: ^World, h: Entity_Handle) -> (copy: Entity_Handle, ok: bool) {
    src := entity_get(world, h) or_return
    e := src^
    e.handle = {}
    entity_make_name_unique(world, &e)
    return hm.add(&world.entities, e)
}
