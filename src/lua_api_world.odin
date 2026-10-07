package blimp

import "core:hash"
import "core:log"

// The script API's World table (世界): what a world script can do to the world it runs in. Each proc is a
// thin @(lua) wrapper — the binding codegen (src/codegen/codegen_lua_binding.odin) marshals the params and
// returns — around a world-layer proc that takes ^World. lua_world() is the world whose script is running;
// called from anywhere else (an engine hook, blimpctl lua without a world) it logs and the proc does nothing.

// Creates an entity and returns its handle. `model` is an asset key like "assets/models/castle.gltf:flag001"; a
// `name` that's taken is made unique (name_1). Entities added during Play don't collide yet.
// zh: 新建实体，返回句柄。`模型` 是资产键，如 "assets/models/castle.gltf:flag001"；
//     名称重复时自动改成 name_1 这样的唯一名。运行中新建的实体暂不参与碰撞。
@(lua=add, table=World, lua_zh="添加")
world_add_lua :: proc(name: string, model: string, position: vec3 = {0, 0, 0}) -> Entity_Handle {
    w := lua_world() or_else nil
    if w == nil do return {}
    return world_add_named(w, name, model, position)
}

// Removes the entity. Every handle to it becomes invalid.
// zh: 删除实体。之后指向它的句柄都无效。
@(lua=remove, table=World, lua_zh="移除")
world_remove_lua :: proc(handle: Entity_Handle) {
    if w, ok := lua_world(); ok do world_remove(w, handle)
}

// The entity named `name`, and whether there is one. Quiet: for when a miss is an answer (the target is gone).
// Cheap enough to call every update.
// zh: 按名称找实体，返回句柄和是否找到。找不到时什么也不报，适合"找不到"本身就是答案的情况（比如目标已经死了）。
//     很便宜，每次更新都查就行。
@(lua=find, table=World, lua_zh="查找")
world_find_lua :: proc(name: string) -> (entity: Entity_Handle, found: bool) {
    w := lua_world() or_else nil
    if w == nil do return {}, false
    return world_find(w, name)
}

// World.find for an entity the script needs: a miss is a bug (renamed or deleted in the editor), so it warns,
// once per name per script load (the error overlay shows it), and returns an invalid handle. Use World.find when a
// miss is an answer (the target is gone).
// zh: 按名称取一个必须存在的实体。找不到说明它在编辑器里被改名或删掉了：在日志和错误浮层里警告
//     （每个名称每次加载脚本只警告一次），返回无效句柄。找不到也正常时用 世界.查找。
@(lua=get, table=World, lua_zh="获取")
world_get_lua :: proc(name: string) -> Entity_Handle {
    w := lua_world() or_else nil
    if w == nil do return {}
    h, ok := world_find(w, name)
    if ok do return h
    s := &w.script
    key := hash.fnv32a(transmute([]u8)name)
    for m in s.missed[:s.missed_count] do if m == key do return {}
    if s.missed_count < len(s.missed) {
        s.missed[s.missed_count] = key
        s.missed_count += 1
    }
    log.warnf("World.get: no entity named '%s' in %s", name, w.title)
    return {}
}

// Game seconds since Play; stops while paused. Animate from this, not from a clock kept in Lua.
// zh: 运行以来的游戏秒数，暂停时停止。动画按它来算，不要在 Lua 里自己计时。
@(lua=time, table=World, lua_zh="时间")
world_time_lua :: proc() -> f64 {
    w := lua_world() or_else nil
    return w != nil ? w.time : 0
}

// The first collision along the ray from `origin`, up to `distance` (direction needn't be unit length): whether it
// hit, where, the surface normal there, and the entity it belongs to.
// zh: 从 `起点` 沿 `方向` 找第一个碰撞，最远 `距离`（方向不必是单位向量）。
//     返回是否命中、命中点、表面法线和命中的实体。
@(lua=raycast, table=World, lua_zh="射线检测")
world_raycast_lua :: proc(origin: vec3, direction: vec3, distance: f32) -> (hit: bool, point: vec3, normal: vec3, entity: Entity_Handle) {
    w := lua_world() or_else nil
    if w == nil do return false, {}, {}, {}
    r, ok := physics_raycast(w, origin, direction, distance)
    return ok, r.point, r.normal, r.entity
}

// Plays a sound file by its project path ("assets/sounds/jump.wav") that isn't anywhere: music, UI, the same volume
// everywhere. False if it didn't start.
// zh: 播放一个不在空间中的声音文件（项目路径，如 "assets/sounds/jump.wav"）：音乐、界面音效，哪里听都一样大。
//     没播出来返回假。
@(lua=play_sound, table=World, lua_zh="播放声音")
world_play_sound_lua :: proc(key: string, volume: f32 = 1) -> bool {
    w := lua_world() or_else nil
    return w != nil && sound_play(w, key, {volume = volume}) != {}
}

// Plays a sound file at a point, fading out with distance over the default range. For something that moves, or a
// range of its own, give an entity the sound and use Entity.play_sound. False if it didn't start.
// zh: 在某一点播放声音文件，按默认范围随距离衰减。会移动的东西、或要自己的范围，就把声音挂在实体上，
//     用 实体.播放声音。没播出来返回假。
@(lua=play_sound_at, table=World, lua_zh="在位置播放声音")
world_play_sound_at_lua :: proc(key: string, position: vec3, volume: f32 = 1) -> bool {
    w := lua_world() or_else nil
    return w != nil && sound_play(w, key, {position = position, positional = true, volume = volume, range = SOUND_DEFAULT_RANGE}) != {}
}

// Sets a light group's brightness for this run (0 = off, 1 = as saved and baked); its flicker pattern still plays on
// top. Not saved. False if no group has that name (case-insensitive).
// zh: 设置光源组这次运行的强度（0 = 关，1 = 和保存、烘焙时一样），闪烁图案照样叠加在上面。不会保存。
//     没有这个名称的组（不区分大小写）时返回假。
@(lua=set_light_group, table=World, lua_zh="设光源组")
world_set_light_group_lua :: proc(name: string, brightness: f32) -> bool {
    w := lua_world() or_else nil
    return w != nil && light_group_set_override(w, name, brightness)
}

// A light group's brightness without its flicker: the value set this run, else the saved one. 0 if no group has that
// name.
// zh: 光源组当前的强度（不含闪烁）：这次运行设过就是设的值，否则是保存的值。没有这个组时返回 0。
@(lua=light_group, table=World, lua_zh="光源组")
world_light_group_lua :: proc(name: string) -> f32 {
    w := lua_world() or_else nil
    if w == nil do return 0
    g := light_group_find(w, name)
    return g == 0 ? 0 : light_group_base_scale(w, g)
}

// Draws a line from `from` to `to` in every view of this world (the game view too) until the next update, so call it
// each update for as long as you want to see it: rays, paths, triggers. Depth-tested, 1 pixel, white by default.
// zh: 从 `起点` 到 `终点` 画一条线，这个世界的所有视口（包括游戏画面）都看得见，只保留到下一次更新，
//     所以要一直看见就每次更新都画：射线、路径、触发区。有深度遮挡，1 像素宽，默认白色。
@(lua=debug_line, table=World, lua_zh="调试线")
world_debug_line_lua :: proc(from: vec3, to: vec3, color: vec4 = {1, 1, 1, 1}) {
    if w, ok := lua_world(); ok do world_debug_line(w, from, to, color)
}
