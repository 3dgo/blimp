package blimp

import "core:math/linalg"
import "core:strings"
import "core:reflect"
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

// Entity predicates: which rule a system applies, by name. Every system that asks "does this entity
// take part?" uses one of these, never raw flag tests.

// Enabled: game systems see it (physics, sound, the game camera).
entity_enabled :: proc(e: ^Entity) -> bool {
    return .Enabled in e.basic_flags
}

// Enabled and not hidden in the editor: its icon and shape (camera frustum, light reach) are drawn.
entity_editor_visible :: proc(e: ^Entity) -> bool {
    return entity_enabled(e) && .Hidden not_in e.basic_flags
}

// Whether the renderer draws `e`: Renderable, Enabled, and not Hidden. Undrawn entities keep their
// transform and mesh instances (indices stay put); they just get no draw command — the check the cull
// pass will make once it moves to the GPU. Picking and marquee skip them too: you can't click what
// you can't see (select them from the entity list instead).
entity_drawn :: proc(e: ^Entity) -> bool {
    return .Renderable in e.basic_static_flags && entity_editor_visible(e)
}

// What takes part in the bake: drawn, static, and not opted out (Cast Indirect). Geometry blocks and
// bounces light; a light has its bounce baked, scaled by its `indirect`.
entity_bakes :: proc(e: ^Entity) -> bool {
    return entity_drawn(e) && .Static in e.basic_static_flags && .Cast_Indirect in e.basic_static_flags
}

// A new entity with the schema's defaults (rotation identity, scale 1, user fields…): the starting point
// of every entity built from text or code, so a field missing from a file gets its default, not zero.
entity_default :: proc() -> (e: Entity) {
    entity_apply_defaults(&e)
    return
}

// An entity's model colour multiplier: its `color` × `intensity` (white × 1 = as authored). A light reads
// the same two fields as its own colour; one entity doesn't take both roles.
entity_tint :: proc(entity: ^Entity) -> vec3 {
    return entity.color * entity.intensity
}

entity_transform :: proc(e: ^Entity) -> mat4 {
    return linalg.matrix4_from_trs_f32(e.position, e.rotation, e.scale)
}

entity_forward :: proc(e: ^Entity) -> vec3 { return linalg.quaternion128_mul_vector3(e.rotation, vec3{0, 0, 1}) }

// Serialization
entity_to_text :: proc(e: ^Entity, allocator := context.allocator) -> string {
    b: strings.Builder
    strings.builder_init(&b, allocator)
    strings.write_string(&b, "[entity]\n")
    serialize_struct(&b, e^)
    return strings.to_string(b)
}

entity_count_blocks :: proc(text: string) -> (n: int) {
    r := Ini_Reader{text = text}
    for line in ini_next(&r) do if line.header && line.section == ENTITY_SECTION do n += 1
    return
}

ENTITY_SECTION :: "entity"   // the [entity] block: levels and the clipboard

// The live slot of `e`'s field at `path` (a name, or a dotted path into nested structs), for code that
// writes a field it names at runtime: levels and the clipboard (deserialize_field), blimpctl set, Lua's
// Entity.set_*. Refuses `hidden` fields (the handle, the selection flag). `saved` (text: files, clipboard,
// blimpctl) also refuses `noserialize` ones, even if a hand-edited file lists one; game code still writes
// those (velocity). Nested paths are checked by their top field.
entity_writable_field :: proc(e: ^Entity, path: string, saved: bool) -> (v: any, ok: bool) {
    top := path
    if d := strings.index_byte(path, '.'); d >= 0 do top = path[:d]
    for i in 0 ..< reflect.struct_field_count(Entity) {
        field := reflect.struct_field_at(Entity, i)
        if field.name != top do continue
        if field_has_tag(field.tag, "hidden") || (saved && field_has_tag(field.tag, "noserialize")) do return
        break
    }
    return struct_field_by_path(e^, path)
}

// Routes one INI `key = value` onto `e`'s field `key` (entity_writable_field), through the value codec in
// serialize.odin.
deserialize_field :: proc(e: ^Entity, key: string, val: string) {
    if v, ok := entity_writable_field(e, key, saved = true); ok do deserialize_value(v, val)
}
