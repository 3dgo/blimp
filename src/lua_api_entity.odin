package blimp

import "base:runtime"

// The script API's Entity table (实体): reading and writing the fields of entities in the world whose script
// is running (lua_world()). Thin @(lua) wrappers; the binding codegen marshals their params and returns.

// The handle still points at an entity in this world. A removed entity's handle never becomes valid again, even when
// its slot is reused.
// zh: 句柄是否还指向这个世界里的实体。实体删掉后句柄永远无效，槽位被重用也不会指向新实体。
@(lua=valid, table=Entity, lua_zh="有效")
entity_valid :: proc(handle: Entity_Handle) -> bool {
    w := lua_world() or_else nil
    if w == nil do return false
    _, ok := entity_get(w, handle)
    return ok
}

// Whether `point` is inside the entity's volume (its Volume field, e.g. Trigger): the box Size covers, centred on
// the entity and turned with it. False if the handle is invalid or the entity isn't a volume. Ask each update:
// if Entity.contains(door, Entity.get_position(player)) then ... end
// zh: `点` 是否在实体的体积（它的“体积”字段，如触发区）里：Size 覆盖的盒子，以实体为中心、随实体旋转。
//     句柄无效或实体不是体积时返回假。每次更新问一次：如果 实体.包含(门, 实体.取位置(玩家)) 那么 … 结束
@(lua=contains, table=Entity, lua_zh="包含")
entity_contains :: proc(handle: Entity_Handle, point: vec3) -> bool {
    e, ok := entity_lua(handle)
    return ok && entity_volume_contains(e, point)
}

//================================ Lua accessors ================================
// Lua accessors for the (schema-generated) entity fields. These are ordinary @(lua) procs —
// the binding codegen marshals their typed params/returns — so nothing here is hand-written
// C or manually registered. Reflection is used only *inside* each proc to resolve the field
// by name, which is what lets schema-added fields be scripted with no binding regeneration.
//
// A single generic entity_get/entity_set can't be an @(lua) proc (its value type is dynamic,
// which the typed marshaller can't represent), so instead the caller picks the type:
//
//   local e = World.find("player")
//   Entity.set_number(e, "health", 100)
//   Entity.set_vec3(e, "position", Vec3(1,2,3))
//   local hp = Entity.get_number(e, "health")

// A number field by its schema id ("intensity", "light_type"): float, integer, enum (its index) or flags (bitmask).
// 0 if the handle is invalid or the field isn't a number.
// zh: 按 schema 里的英文字段名读数字字段（如 "intensity"、"light_type"）：浮点、整数、
//     枚举（序号）、标志位（位掩码）。句柄无效或不是数字字段时返回 0。
@(lua=get_number, table=Entity, lua_zh="取数")
entity_get_number :: proc(handle: Entity_Handle, field: string) -> f64 {
    v, ok := entity_field(handle, field)
    if !ok do return 0
    #partial switch info in type_info_of(v.id).variant {
    case runtime.Type_Info_Float:   return f64(v.(f32))
    case runtime.Type_Info_Integer: return f64(entity_read_int(v, info.signed))
    case runtime.Type_Info_Bit_Set: return f64((^u64)(v.data)^)
    case runtime.Type_Info_Boolean: return v.(bool) ? 1 : 0
    case runtime.Type_Info_Named:
        #partial switch _ in info.base.variant {
        case runtime.Type_Info_Enum: return f64(entity_read_int(v, false))
        }
    }
    return 0
}

// Writes a number field (see get_number). Does nothing if the handle is invalid or the field isn't a number.
// zh: 写数字字段（见 取数）。句柄无效或不是数字字段时什么也不做。
@(lua=set_number, table=Entity, lua_zh="设数")
entity_set_number :: proc(handle: Entity_Handle, field: string, value: f64) {
    v, ok := entity_field(handle, field, write = true)
    if !ok do return
    #partial switch info in type_info_of(v.id).variant {
    case runtime.Type_Info_Float:   (^f32)(v.data)^ = f32(value)
    case runtime.Type_Info_Integer: entity_write_int(v, i64(value))
    case runtime.Type_Info_Bit_Set: (^u64)(v.data)^ = u64(i64(value))
    case runtime.Type_Info_Named:
        #partial switch _ in info.base.variant {
        case runtime.Type_Info_Enum: entity_write_int(v, i64(value))
        }
    }
}

// A bool field by its schema id. False if the handle is invalid or the field isn't a bool.
// zh: 按英文字段名读布尔字段。句柄无效或不是布尔字段时返回假。
@(lua=get_bool, table=Entity, lua_zh="取布尔")
entity_get_bool :: proc(handle: Entity_Handle, field: string) -> bool {
    v, ok := entity_field(handle, field)
    if !ok do return false
    if _, is_b := type_info_of(v.id).variant.(runtime.Type_Info_Boolean); is_b do return v.(bool)
    return false
}

// Writes a bool field by its schema id. Does nothing if the handle is invalid or the field isn't a bool.
// zh: 写布尔字段。句柄无效或不是布尔字段时什么也不做。
@(lua=set_bool, table=Entity, lua_zh="设布尔")
entity_set_bool :: proc(handle: Entity_Handle, field: string, value: bool) {
    v, ok := entity_field(handle, field, write = true)
    if !ok do return
    if _, is_b := type_info_of(v.id).variant.(runtime.Type_Info_Boolean); is_b do (^bool)(v.data)^ = value
}

// A text field by its schema id: "name", or an asset key like "model" or "sound". "" if the handle is invalid or the
// field isn't text.
// zh: 按英文字段名读文本字段："name"，或 "model"、"sound" 这样的资产键。句柄无效或不是文本字段时返回 ""。
@(lua=get_string, table=Entity, lua_zh="取文本")
entity_get_string :: proc(handle: Entity_Handle, field: string) -> string {
    v, ok := entity_field(handle, field)
    if !ok do return ""
    #partial switch _ in type_info_of(v.id).variant {
    case runtime.Type_Info_String:                       return v.(string)
    case runtime.Type_Info_Fixed_Capacity_Dynamic_Array: if s, is_sbuf := sbuf_any_str(v); is_sbuf do return s
    }
    return ""
}

// Writes a text field by its schema id. A "name" another entity already has is made unique (name_1).
// zh: 写文本字段。把 "name" 改成别的实体已有的名称时，会自动改成唯一名（如 name_1）。
@(lua=set_string, table=Entity, lua_zh="设文本")
entity_set_string :: proc(handle: Entity_Handle, field: string, value: string) {
    v, ok := entity_field(handle, field, write = true)
    if !ok do return
    #partial switch _ in type_info_of(v.id).variant {
    case runtime.Type_Info_String:                       (^string)(v.data)^ = asset_intern(value)   // string fields are asset keys
    case runtime.Type_Info_Fixed_Capacity_Dynamic_Array: sbuf_any_set(v, value)
    }
    if field == "name" do if w, wok := lua_world(); wok do world_fix_duplicate_name(w, handle)   // names stay unique
}

// A vec3 field by its schema id ("velocity", "color"). Zero if the handle is invalid or the field isn't a vec3.
// zh: 按英文字段名读矢量3字段（如 "velocity"、"color"）。句柄无效或不是矢量3字段时返回零矢量。
@(lua=get_vec3, table=Entity, lua_zh="取矢量")
entity_get_vec3 :: proc(handle: Entity_Handle, field: string) -> vec3 {
    v, ok := entity_field(handle, field)
    if !ok do return {}
    if a, is_a := type_info_of(v.id).variant.(runtime.Type_Info_Array); is_a && a.count == 3 do return (^vec3)(v.data)^
    return {}
}

// Writes a vec3 field by its schema id. Does nothing if the handle is invalid or the field isn't a vec3.
// zh: 写矢量3字段。句柄无效或不是矢量3字段时什么也不做。
@(lua=set_vec3, table=Entity, lua_zh="设矢量")
entity_set_vec3 :: proc(handle: Entity_Handle, field: string, value: vec3) {
    v, ok := entity_field(handle, field, write = true)
    if !ok do return
    if a, is_a := type_info_of(v.id).variant.(runtime.Type_Info_Array); is_a && a.count == 3 do (^vec3)(v.data)^ = value
}

// A quaternion field by its schema id. Identity if the handle is invalid or the field isn't a quaternion.
// zh: 按英文字段名读四元数字段。句柄无效或不是四元数字段时返回单位四元数。
@(lua=get_quat, table=Entity, lua_zh="取四元数")
entity_get_quat :: proc(handle: Entity_Handle, field: string) -> quat {
    v, ok := entity_field(handle, field)
    if !ok do return quat(1)
    if _, is_q := type_info_of(v.id).variant.(runtime.Type_Info_Quaternion); is_q do return (^quat)(v.data)^
    return quat(1)
}

// Writes a quaternion field by its schema id. Does nothing if the handle is invalid or the field isn't a quaternion.
// zh: 写四元数字段。句柄无效或不是四元数字段时什么也不做。
@(lua=set_quat, table=Entity, lua_zh="设四元数")
entity_set_quat :: proc(handle: Entity_Handle, field: string, value: quat) {
    v, ok := entity_field(handle, field, write = true)
    if !ok do return
    if _, is_q := type_info_of(v.id).variant.(runtime.Type_Info_Quaternion); is_q do (^quat)(v.data)^ = value
}

//================================ Built-in fields ================================
// Typed shortcuts for the fields every entity has (transform, Hidden), so a script writes
// Entity.translate(e, d) instead of Entity.set_vec3(e, "position", Entity.get_vec3(e, "position") + d).
// Same live slot as the by-name accessors; a stale handle reads zero/identity and writes nothing.

// World-space position. Zero if the handle is invalid.
// zh: 世界坐标的位置。句柄无效时返回零矢量。
@(lua=get_position, table=Entity, lua_zh="取位置")
entity_get_position :: proc(handle: Entity_Handle) -> vec3 {
    e, ok := entity_lua(handle)
    return ok ? e.position : {}
}

// Puts the entity at a world-space position, ignoring collision (Entity.move_character collides).
// zh: 把实体放到世界坐标的这个位置，不管碰撞（要碰撞用 实体.角色移动）。
@(lua=set_position, table=Entity, lua_zh="设位置")
entity_set_position :: proc(handle: Entity_Handle, position: vec3) {
    if e, ok := entity_lua(handle); ok do e.position = position
}

// Moves by `delta` in world space, ignoring collision.
// zh: 位置加上 `位移`（世界坐标），不管碰撞。
@(lua=translate, table=Entity, lua_zh="平移")
entity_translate :: proc(handle: Entity_Handle, delta: vec3) {
    if e, ok := entity_lua(handle); ok do e.position += delta
}

// Rotation. Identity if the handle is invalid.
// zh: 朝向（四元数）。句柄无效时返回单位四元数。
@(lua=get_rotation, table=Entity, lua_zh="取朝向")
entity_get_rotation :: proc(handle: Entity_Handle) -> quat {
    e, ok := entity_lua(handle)
    return ok ? e.rotation : quat(1)
}

// Sets the rotation.
// zh: 设置朝向（四元数）。
@(lua=set_rotation, table=Entity, lua_zh="设朝向")
entity_set_rotation :: proc(handle: Entity_Handle, rotation: quat) {
    if e, ok := entity_lua(handle); ok do e.rotation = rotation
}

// Turns by `by` in the entity's local space: rotation = rotation * by.
// zh: 在本地坐标里转动：朝向 = 朝向 * `转动`。
@(lua=rotate, table=Entity, lua_zh="旋转")
entity_rotate :: proc(handle: Entity_Handle, by: quat) {
    if e, ok := entity_lua(handle); ok do e.rotation = e.rotation * by
}

// Scale per axis. Zero if the handle is invalid.
// zh: 每个轴的缩放倍数。句柄无效时返回零矢量。
@(lua=get_scale, table=Entity, lua_zh="取缩放")
entity_get_scale :: proc(handle: Entity_Handle) -> vec3 {
    e, ok := entity_lua(handle)
    return ok ? e.scale : {}
}

// Sets the scale per axis.
// zh: 设置每个轴的缩放倍数。
@(lua=set_scale, table=Entity, lua_zh="设缩放")
entity_set_scale :: proc(handle: Entity_Handle, scale: vec3) {
    if e, ok := entity_lua(handle); ok do e.scale = scale
}

// Sets Hidden: the entity isn't drawn. Collision and sound are unaffected.
// zh: 隐藏实体：不再绘制。碰撞和声音不受影响。
@(lua=hide, table=Entity, lua_zh="隐藏")
entity_hide :: proc(handle: Entity_Handle) {
    if e, ok := entity_lua(handle); ok do e.basic_flags += {.Hidden}
}

// Clears Hidden: the entity is drawn again.
// zh: 取消隐藏，重新绘制。
@(lua=unhide, table=Entity, lua_zh="取消隐藏")
entity_unhide :: proc(handle: Entity_Handle) {
    if e, ok := entity_lua(handle); ok do e.basic_flags -= {.Hidden}
}

// Hidden is set (Entity.hide). False if the handle is invalid.
// zh: 是否被隐藏（见 实体.隐藏）。句柄无效时返回假。
@(lua=is_hidden, table=Entity, lua_zh="是否隐藏")
entity_is_hidden :: proc(handle: Entity_Handle) -> bool {
    e, ok := entity_lua(handle)
    return ok && .Hidden in e.basic_flags
}

// Entity `handle` in the script's world; false if there's no world or the handle is stale.
@(private="file")
entity_lua :: proc(handle: Entity_Handle) -> (^Entity, bool) {
    w := lua_world() or_else nil
    if w == nil do return nil, false
    return entity_get(w, handle)
}

// The `any` for entity `handle`'s field named `name` in the script's world, pointing at the live slot (so
// writes through it hit the entity). `name` may be a dotted path into nested struct fields. `write`: only a
// field code may write (entity_writable_field: not the handle or the selection; velocity yes). ok = false if the handle
// is stale or the path doesn't resolve.
@(private = "file")
entity_field :: proc(handle: Entity_Handle, name: string, write := false) -> (v: any, ok: bool) {
    w := lua_world() or_return
    e := entity_get(w, handle) or_return
    if write do return entity_writable_field(e, name, saved = false)
    return struct_field_by_path(e^, name)
}

@(private = "file")
entity_read_int :: proc(v: any, signed: bool) -> i64 {
    switch type_info_of(v.id).size {
    case 1: return signed ? i64((^i8)(v.data)^)  : i64((^u8)(v.data)^)
    case 2: return signed ? i64((^i16)(v.data)^) : i64((^u16)(v.data)^)
    case 8: return signed ? (^i64)(v.data)^      : i64((^u64)(v.data)^)
    case:   return signed ? i64((^i32)(v.data)^) : i64((^u32)(v.data)^)
    }
}

@(private = "file")
entity_write_int :: proc(v: any, n: i64) {
    switch type_info_of(v.id).size {
    case 1: (^u8)(v.data)^  = u8(n)
    case 2: (^u16)(v.data)^ = u16(n)
    case 8: (^u64)(v.data)^ = u64(n)
    case:   (^u32)(v.data)^ = u32(n)
    }
}

// The character mover: moves the entity by `delta` as a capsule of `radius` and total `height` standing on its
// position, sliding along collision (walls stop it, slopes and steps it rides), and writes the result to its
// position. True if it ends standing on ground. delta is already scaled by dt, gravity included: Lua decides how
// things fall.
// zh: 角色移动：把实体当成站在它位置上的胶囊体（`半径`、总`高度`），移动 `位移`，
//     沿碰撞面滑动：撞墙停下，斜坡和台阶会走上去。结果直接写进实体的位置。
//     结束时站在地面上返回真。`位移` 要自己乘好时间差，重力也算在里面。
@(lua=move_character, table=Entity, lua_zh="角色移动")
entity_move_character_lua :: proc(handle: Entity_Handle, delta: vec3, radius: f32, height: f32) -> bool {
    w := lua_world() or_else nil
    return w != nil && physics_move_character(w, handle, delta, radius, height)
}

// Plays the entity's own sound (its Sound, Volume, Range and Sound Flags), following it as it moves. False if it
// didn't start.
// zh: 按实体自己的 sound、volume、range、sound_flags 字段播放声音，声音跟着实体移动。没播出来返回假。
@(lua=play_sound, table=Entity, lua_zh="播放声音")
entity_play_sound_lua :: proc(handle: Entity_Handle) -> bool {
    w := lua_world() or_else nil
    return w != nil && entity_sound_play(w, handle) != {}
}

// Stops the entity's sound.
// zh: 停止这个实体的声音。
@(lua=stop_sound, table=Entity, lua_zh="停止声音")
entity_stop_sound_lua :: proc(handle: Entity_Handle) {
    if w, ok := lua_world(); ok do entity_sound_stop(w, handle)
}
