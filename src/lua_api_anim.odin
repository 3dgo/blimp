package blimp

import hm "core:container/handle_map"

// The animation API, table Anim / 动画 (claude/animation.md): thin wrappers over world_anim.odin on the
// running script's world. Each update samples clips into poses, combines them and outputs one per entity; a
// pose is only good in the update that made it. Clip and joint names are the model's own (Walk, b_Head_05).

// A pose of the entity's clip (the glTF animation's name) at its time, advanced by this update's dt × speed. The
// clip's time starts at 0 the first update it's sampled and is forgotten the first update it isn't. loop = false
// holds the last frame.
// zh: 实体的片段（glTF 里动画的名字）在它自己时间上的姿态，每次更新前进 时间差 × `速度`。
//     第一次采样时从 0 开始；某次更新没采样它，时间就被丢掉，下次从头开始。`循环` 为假时停在最后一帧。
@(lua=sample, table=Anim, lua_zh="采样")
anim_sample_lua :: proc(e: Entity_Handle, clip: string, speed: f32 = 1, loop: bool = true) -> Anim_Pose {
    w := lua_world() or_else nil
    return w != nil ? anim_sample(w, e, clip, speed, loop) : {}
}

// Interpolates every joint from a to b by weight (0 = a, 1 = b). Both poses must come from the same entity.
// zh: 按 `权重` 逐个关节从 `甲` 插值到 `乙`（0 = 甲，1 = 乙）。两个姿态必须来自同一个实体。
@(lua=blend, table=Anim, lua_zh="混合")
anim_blend_lua :: proc(a: Anim_Pose, b: Anim_Pose, weight: f32) -> Anim_Pose {
    w := lua_world() or_else nil
    return w != nil ? anim_blend(w, a, b, weight) : {}
}

// `over` on top of `base` for the named joint and everything below it (e.g. the upper body from the spine), by
// weight. The edge fades over a few joints.
// zh: 在关节 `关节名` 和它下面的所有关节上，用 `上` 盖住 `底`，按 `权重`
//     （比如从脊椎往上挥手，腿继续走）。边界会在几个关节里渐变。
@(lua=layer, table=Anim, lua_zh="叠层")
anim_layer_lua :: proc(base: Anim_Pose, over: Anim_Pose, joint: string, weight: f32) -> Anim_Pose {
    w := lua_world() or_else nil
    return w != nil ? anim_layer(w, base, over, joint, weight) : {}
}

// Shows the pose on the entity this update; one per entity per update. A clip that started this update eases in
// from what was shown over about blend_time seconds. An animated entity given no pose goes back to its rest pose
// (or its `anim` clip).
// zh: 这次更新让实体显示这个姿态，每个实体每次更新输出一个。换了片段会从刚才显示的姿态自动过渡，
//     约 `过渡秒数` 秒。没有输出姿态的实体回到原始姿态（或它的 anim 字段里的片段）。
@(lua=output, table=Anim, lua_zh="输出")
anim_output_lua :: proc(e: Entity_Handle, pose: Anim_Pose, blend_time: f32 = ANIM_BLEND_TIME) {
    w := lua_world() or_else nil
    if w != nil do anim_output(w, e, pose, blend_time)
}

// Moves a playing clip to `time` seconds without firing its events, easing in from what was shown.
// zh: 把正在播放的片段跳到第 `秒数` 秒，不触发途经的事件，并从当前显示的姿态过渡过去。
@(lua=seek, table=Anim, lua_zh="跳转")
anim_seek_lua :: proc(e: Entity_Handle, clip: string, time: f32) {
    w := lua_world() or_else nil
    if w != nil do anim_seek(w, e, clip, time)
}

// The clip is playing on the entity: sampled last update (or this one), and looping or not at its end. What a
// script asks instead of remembering "attacking".
// zh: 片段是否正在这个实体上播放：上次或这次更新采样过它，并且循环或还没播到结尾。
//     用它判断"正在攻击"，不要自己记状态。
@(lua=playing, table=Anim, lua_zh="播放中")
anim_playing_lua :: proc(e: Entity_Handle, clip: string) -> bool {
    w := lua_world() or_else nil
    return w != nil && anim_playing(w, e, clip)
}

// The playing clip's time and its length in seconds; 0, 0 if it isn't playing.
// zh: 正在播放的片段的当前秒数和总长度；没在播放时返回 0, 0。
@(lua=time, table=Anim, lua_zh="时间")
anim_time_lua :: proc(e: Entity_Handle, clip: string) -> (time: f32, length: f32) {
    w := lua_world() or_else nil
    if w == nil do return 0, 0
    r, c := anim_find_record(w, e, clip)
    if r == nil do return 0, 0
    return r.time, c.duration
}

// How fast the clip travelled before import made it play in place, in metres per second at the entity's scale (0
// if it was authored in place). Playing it at speed / root_speed keeps the feet from sliding.
// zh: 导入时为了原地播放而去掉的移动速度（米/秒，已乘实体缩放）；本来就是原地制作的片段为 0。
//     按 速度 / 移动速度 播放，脚就不会滑。
@(lua=root_speed, table=Anim, lua_zh="移动速度")
anim_root_speed_lua :: proc(e: Entity_Handle, clip: string) -> f32 {
    w := lua_world() or_else nil
    if w == nil do return 0
    ent, ok := hm.get(&w.entities, e)
    if !ok do return 0
    model, has_model := asset_system.models[ent.model]
    if !has_model || model.skeleton == NO_SKELETON do return 0
    i, found := asset_system.skeletons[model.skeleton].clips[clip]
    if !found do return 0
    return asset_system.clips[i].root_speed * (ent.scale.x + ent.scale.z) / 2
}

// A joint's world position and rotation, as of the entity's last pose (this update's after Anim.output).
// zh: 关节的世界位置和朝向，取自实体最后一次的姿态（在 动画.输出 之后调用就是这一帧的）。
@(lua=joint, table=Anim, lua_zh="关节")
anim_joint_lua :: proc(e: Entity_Handle, joint: string) -> (position: vec3, rotation: quat) {
    w := lua_world() or_else nil
    if w == nil do return {}, 1
    pos, rot, _ := anim_joint(w, e, joint)
    return pos, rot
}
