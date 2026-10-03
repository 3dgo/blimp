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
    v, ok := entity_field(handle, field)
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
    v, ok := entity_field(handle, field)
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
    v, ok := entity_field(handle, field)
    if !ok do return
    #partial switch _ in type_info_of(v.id).variant {
    case runtime.Type_Info_String:                       (^string)(v.data)^ = asset_intern(value)
    case runtime.Type_Info_Fixed_Capacity_Dynamic_Array: sbuf_any_set(v, value)
    }
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
    v, ok := entity_field(handle, field)
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
    v, ok := entity_field(handle, field)
    if !ok do return
    if _, is_q := type_info_of(v.id).variant.(runtime.Type_Info_Quaternion); is_q do (^quat)(v.data)^ = value
}

// The `any` for entity `handle`'s field named `name`, pointing at the live slot (so writes
// through it hit the entity). `name` may be a dotted path into nested struct fields
// ("light_groups.group_1.scale" in a settings struct). ok=false if the handle is stale or the path doesn't resolve.
@(private = "file")
entity_field :: proc(handle: Entity_Handle, name: string) -> (v: any, ok: bool) {
    w := lua_world() or_return
    e := entity_get(w, handle) or_return
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
