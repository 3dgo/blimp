package blimp

import "base:runtime"
import "core:math/linalg"
import "core:strings"
import "core:reflect"
import vmem "core:mem/virtual"
import hm "core:container/handle_map"

MAX_ENTITIES :: 4096   // per world. Undo copies the whole map per step (editor_undo.odin), so this sets its cost too.
MAX_LIGHTS :: 256
Entity_Handle_Map :: hm.Static_Handle_Map(MAX_ENTITIES, Entity, Entity_Handle)
@(lua_int="u32") Entity_Handle :: distinct hm.Handle32   // marshalled to Lua as an integer

// The `Entity` struct, its flag enums and bit_set aliases are GENERATED from
// entity_schema.ini into src/gen_entity.odin (see src/codegen/codegen_entity.odin). Edit
// the schema, not the generated file. The procs below are hand-written and reference the
// generated fields; deleting a field they use is a compile error, by design.

entity_get :: proc(world: ^World, handle: Entity_Handle) -> (^Entity, bool) #optional_ok {
    return hm.get(&world.entities, handle)
}

@(lua=valid, table=Entity, lua_zh="有效")
entity_valid :: proc(handle: Entity_Handle) -> bool {
    _, ok := entity_get(lua_world(), handle)
    return ok
}

// Whether the renderer draws `e`: Renderable, Enabled, and not Hidden. Undrawn entities keep their
// transform and mesh instances (indices stay put); they just get no draw command — the check the cull
// pass will make once it moves to the GPU. Picking and marquee skip them too: you can't click what
// you can't see (select them from the entity list instead).
entity_drawn :: proc(e: ^Entity) -> bool {
    return .Renderable in e.basic_static_flags && .Enabled in e.basic_flags && .Hidden not_in e.basic_flags
}

// An entity's asset references as interned keys (asset_intern), so they outlive whatever arena they were
// read into (a level, the clipboard, a remote command) and survive an asset reload. Call after reading
// fields from text.
entity_intern_keys :: proc(e: ^Entity) {
    e.model = asset_model_key(e.model)
    e.sound = asset_intern(e.sound)
}

entity_transform :: proc(e: ^Entity) -> mat4 {
    return linalg.matrix4_from_trs_f32(e.position, e.rotation, e.scale)
}

entity_forward :: proc(e: ^Entity) -> vec3 { return linalg.quaternion128_mul_vector3(e.rotation, vec3{0, 0, 1}) }
entity_right   :: proc(e: ^Entity) -> vec3 { return linalg.quaternion128_mul_vector3(e.rotation, vec3{1, 0, 0}) }
entity_up      :: proc(e: ^Entity) -> vec3 { return linalg.quaternion128_mul_vector3(e.rotation, vec3{0, 1, 0}) }

create_entites :: proc(w: ^World) {
    world_add(w, "car",    "assets/models/cars.gltf:car",    { 1, 0, 0})
    world_add(w, "police", "assets/models/cars.gltf:police", {-1, 0, 0})
    world_add(w, "floor",  "assets/models/cars.gltf:floor",  { 0, 0, 0})
}

// Serialization
entity_to_text :: proc(e: ^Entity, allocator := context.allocator) -> string {
    b: strings.Builder
    strings.builder_init(&b, allocator)
    strings.write_string(&b, "[entity]\n")
    serialize_struct(&b, e^)
    return strings.to_string(b)
}

// `allocator` owns any string fields the block sets — pass the arena of the world `e` lives in.
entity_apply_text :: proc(e: ^Entity, text: string, allocator: runtime.Allocator, skip_tags: []string = {}) {
    txt := text
    for line in strings.split_lines_iterator(&txt) {
        trimmed := strings.trim_space(line)
        if len(trimmed) == 0 || trimmed[0] == '#' || trimmed[0] == ';' || trimmed[0] == '[' do continue
        eq := strings.index_byte(trimmed, '=')
        if eq < 0 do continue
        deserialize_field(e, strings.trim_space(trimmed[:eq]), strings.trim_space(trimmed[eq+1:]), allocator, skip_tags)
    }
}

entity_count_blocks :: proc(text: string) -> (n: int) {
    txt := text
    for line in strings.split_lines_iterator(&txt) {
        t := strings.trim_space(line)
        if len(t) >= 2 && t[0] == '[' && t[len(t)-1] == ']' && strings.trim_space(t[1:len(t)-1]) == "entity" do n += 1
    }
    return
}

// Routes one INI `key = value` onto Entity field `key` (dotted paths descend into nested structs).
// Skips fields tagged `noserialize` or any tag in `skip_tags` (identity/placement, for paste-over).
// The generic value codec lives in serialize.odin; this is the Entity-aware router around it.
deserialize_field :: proc(e: ^Entity, key: string, val: string, allocator: runtime.Allocator, skip_tags: []string = {}) {
    // Guard: never write a noserialize top-level field (e.g. handle), even if a hand-edited
    // scene lists it. Nested keys carry a '.'; their top segment is the entity field.
    top := key
    if d := strings.index_byte(key, '.'); d >= 0 do top = key[:d]
    for i in 0 ..< reflect.struct_field_count(Entity) {
        field := reflect.struct_field_at(Entity, i)
        if field.name == top {
            if field_has_tag(field.tag, "noserialize") do return
            for st in skip_tags do if field_has_tag(field.tag, st) do return
            break
        }
    }
    if v, ok := struct_field_by_path(e^, key); ok {
        deserialize_value(v, val, allocator)
    }
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
    case runtime.Type_Info_String:                       (^string)(v.data)^ = strings.clone(value, vmem.arena_allocator(&lua_world().arena))
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
// ("transform.position"). ok=false if the handle is stale or the path doesn't resolve.
@(private = "file")
entity_field :: proc(handle: Entity_Handle, name: string) -> (v: any, ok: bool) {
    e := entity_get(lua_world(), handle) or_return
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