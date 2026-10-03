package blimp

// The script API's World table (世界): what a world script can do to the world it runs in. Each proc is a
// thin @(lua) wrapper — the binding codegen (src/codegen/codegen_lua_binding.odin) marshals the params and
// returns — around a world-layer proc that takes ^World. lua_world() is the world whose script is running;
// called from anywhere else (an engine hook, blimpctl lua without a world) it logs and the proc does nothing.

@(lua=add, table=World, lua_zh="添加")
world_add_lua :: proc(name: string, model: string, position: vec3 = {0, 0, 0}) -> Entity_Handle {
    w := lua_world() or_else nil
    if w == nil do return {}
    return world_add_named(w, name, model, position)
}

@(lua=remove, table=World, lua_zh="移除")
world_remove_lua :: proc(handle: Entity_Handle) {
    if w, ok := lua_world(); ok do world_remove(w, handle)
}

@(lua=find, table=World, lua_zh="查找")
world_find_lua :: proc(name: string) -> (Entity_Handle, bool) {
    w := lua_world() or_else nil
    if w == nil do return {}, false
    return world_find(w, name)
}

// Game seconds since Play (World.time): animate from this, not from a clock kept in Lua. Stops while paused.
@(lua=time, table=World, lua_zh="时间")
world_time_lua :: proc() -> f64 {
    w := lua_world() or_else nil
    return w != nil ? w.time : 0
}

// The first static collision along the ray (direction needn't be unit length), up to `distance`: whether it hit,
// where, the surface normal there, and the entity it belongs to.
@(lua=raycast, table=World, lua_zh="射线检测")
world_raycast_lua :: proc(origin: vec3, direction: vec3, distance: f32) -> (bool, vec3, vec3, Entity_Handle) {
    w := lua_world() or_else nil
    if w == nil do return false, {}, {}, {}
    hit, ok := physics_raycast(w, origin, direction, distance)
    return ok, hit.point, hit.normal, hit.entity
}

// A sound file (its project path) that isn't anywhere: music, UI, the same volume everywhere.
@(lua=play_sound, table=World, lua_zh="播放声音")
world_play_sound_lua :: proc(key: string, volume: f32 = 1) -> bool {
    w := lua_world() or_else nil
    return w != nil && sound_play(w, key, {volume = volume}) != {}
}

// A sound file at a point, fading out over SOUND_DEFAULT_RANGE. For something that moves, or a range of
// its own, give an entity the sound and use Entity.play_sound.
@(lua=play_sound_at, table=World, lua_zh="在位置播放声音")
world_play_sound_at_lua :: proc(key: string, position: vec3, volume: f32 = 1) -> bool {
    w := lua_world() or_else nil
    return w != nil && sound_play(w, key, {position = position, positional = true, volume = volume, range = SOUND_DEFAULT_RANGE}) != {}
}

// Sets a light group's scale at runtime (0 = off, 1 = as saved/baked); false if no group has that name.
@(lua=set_light_group, table=World, lua_zh="设光源组")
world_set_light_group_lua :: proc(name: string, scale: f32) -> bool {
    w := lua_world() or_else nil
    return w != nil && light_group_set_override(w, name, scale)
}

// A light group's scale before its flicker (the runtime value if set, else the saved one); 0 if unknown.
@(lua=light_group, table=World, lua_zh="光源组")
world_light_group_lua :: proc(name: string) -> f32 {
    w := lua_world() or_else nil
    if w == nil do return 0
    g := light_group_find(w, name)
    return g == 0 ? 0 : light_group_base_scale(w, g)
}
