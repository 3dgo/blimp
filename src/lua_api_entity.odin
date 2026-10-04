package blimp

import "base:runtime"

// The script API's Entity table (实体): reading and writing the fields of entities in the world whose script
// is running (lua_world()). Thin @(lua) wrappers; the binding codegen marshals their params and returns.

@(lua=valid, table=Entity, lua_zh="有效")
entity_valid :: proc(handle: Entity_Handle) -> bool {
    w := lua_world() or_else nil
    if w == nil do return false
    _, ok := entity_get(w, handle)
    return ok
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

@(lua=get_bool, table=Entity, lua_zh="取布尔")
entity_get_bool :: proc(handle: Entity_Handle, field: string) -> bool {
    v, ok := entity_field(handle, field)
    if !ok do return false
    if _, is_b := type_info_of(v.id).variant.(runtime.Type_Info_Boolean); is_b do return v.(bool)
    return false
}

@(lua=set_bool, table=Entity, lua_zh="设布尔")
entity_set_bool :: proc(handle: Entity_Handle, field: string, value: bool) {
    v, ok := entity_field(handle, field, write = true)
    if !ok do return
    if _, is_b := type_info_of(v.id).variant.(runtime.Type_Info_Boolean); is_b do (^bool)(v.data)^ = value
}

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

@(lua=get_vec3, table=Entity, lua_zh="取矢量")
entity_get_vec3 :: proc(handle: Entity_Handle, field: string) -> vec3 {
    v, ok := entity_field(handle, field)
    if !ok do return {}
    if a, is_a := type_info_of(v.id).variant.(runtime.Type_Info_Array); is_a && a.count == 3 do return (^vec3)(v.data)^
    return {}
}

@(lua=set_vec3, table=Entity, lua_zh="设矢量")
entity_set_vec3 :: proc(handle: Entity_Handle, field: string, value: vec3) {
    v, ok := entity_field(handle, field, write = true)
    if !ok do return
    if a, is_a := type_info_of(v.id).variant.(runtime.Type_Info_Array); is_a && a.count == 3 do (^vec3)(v.data)^ = value
}

@(lua=get_quat, table=Entity, lua_zh="取四元数")
entity_get_quat :: proc(handle: Entity_Handle, field: string) -> quat {
    v, ok := entity_field(handle, field)
    if !ok do return quat(1)
    if _, is_q := type_info_of(v.id).variant.(runtime.Type_Info_Quaternion); is_q do return (^quat)(v.data)^
    return quat(1)
}

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

@(lua=get_position, table=Entity, lua_zh="取位置")
entity_get_position :: proc(handle: Entity_Handle) -> vec3 {
    e, ok := entity_lua(handle)
    return ok ? e.position : {}
}

@(lua=set_position, table=Entity, lua_zh="设位置")
entity_set_position :: proc(handle: Entity_Handle, position: vec3) {
    if e, ok := entity_lua(handle); ok do e.position = position
}

// Moves by `delta` in world space.
@(lua=translate, table=Entity, lua_zh="平移")
entity_translate :: proc(handle: Entity_Handle, delta: vec3) {
    if e, ok := entity_lua(handle); ok do e.position += delta
}

@(lua=get_rotation, table=Entity, lua_zh="取朝向")
entity_get_rotation :: proc(handle: Entity_Handle) -> quat {
    e, ok := entity_lua(handle)
    return ok ? e.rotation : quat(1)
}

@(lua=set_rotation, table=Entity, lua_zh="设朝向")
entity_set_rotation :: proc(handle: Entity_Handle, rotation: quat) {
    if e, ok := entity_lua(handle); ok do e.rotation = rotation
}

// Turns by `by` in the entity's local space (rotation * by, as in the castle walkthrough).
@(lua=rotate, table=Entity, lua_zh="旋转")
entity_rotate :: proc(handle: Entity_Handle, by: quat) {
    if e, ok := entity_lua(handle); ok do e.rotation = e.rotation * by
}

@(lua=get_scale, table=Entity, lua_zh="取缩放")
entity_get_scale :: proc(handle: Entity_Handle) -> vec3 {
    e, ok := entity_lua(handle)
    return ok ? e.scale : {}
}

@(lua=set_scale, table=Entity, lua_zh="设缩放")
entity_set_scale :: proc(handle: Entity_Handle, scale: vec3) {
    if e, ok := entity_lua(handle); ok do e.scale = scale
}

// Hidden: not drawn (entity_drawn). Collision and sound are unaffected.
@(lua=hide, table=Entity, lua_zh="隐藏")
entity_hide :: proc(handle: Entity_Handle) {
    if e, ok := entity_lua(handle); ok do e.basic_flags += {.Hidden}
}

@(lua=unhide, table=Entity, lua_zh="取消隐藏")
entity_unhide :: proc(handle: Entity_Handle) {
    if e, ok := entity_lua(handle); ok do e.basic_flags -= {.Hidden}
}

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
// position, sliding along static collision (walls stop it, slopes and steps it rides). True if it ends standing on
// ground. Gravity is part of delta: Lua decides how things fall.
@(lua=move_character, table=Entity, lua_zh="角色移动")
entity_move_character_lua :: proc(handle: Entity_Handle, delta: vec3, radius: f32, height: f32) -> bool {
    w := lua_world() or_else nil
    return w != nil && physics_move_character(w, handle, delta, radius, height)
}

// Plays the entity's own sound (its Sound, Volume, Range and Sound Flags), following it. False if it
// didn't start.
@(lua=play_sound, table=Entity, lua_zh="播放声音")
entity_play_sound_lua :: proc(handle: Entity_Handle) -> bool {
    w := lua_world() or_else nil
    return w != nil && entity_sound_play(w, handle) != {}
}

@(lua=stop_sound, table=Entity, lua_zh="停止声音")
entity_stop_sound_lua :: proc(handle: Entity_Handle) {
    if w, ok := lua_world(); ok do entity_sound_stop(w, handle)
}
