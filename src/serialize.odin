package blimp

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:reflect"

// Generic, reflection-driven struct <-> INI-line serialization. No scene/Entity knowledge:
// it operates on any struct via `any`, so the scene loader (world_scene.odin), the clipboard/undo
// entity text round-trip (world_entity.odin), and future consumers all share one codec. Handles the
// field types entities use (string, sbuf, bool, f32, float vectors, quaternion, bit_set flags,
// integers, enums); extend the switches for more.
//
// Format: flat `key = value` lines; nested struct fields become dotted keys
// ("transform.position"). Vectors and quaternions are comma-separated floats.

// Recurses into nested struct fields, emitting their leaves as dotted keys ("transform.position")
// so the flat INI can round-trip composite types. Non-struct aggregates (vectors, quaternions,
// sbuf, bit_sets) are leaves, written by serialize_value. A field tagged `noserialize` is skipped.
serialize_struct :: proc(b: ^strings.Builder, value: any, prefix := "") {
    n := reflect.struct_field_count(value.id)
    for i in 0..<n {
        field := reflect.struct_field_at(value.id, i)
        if field_has_tag(field.tag, "noserialize") do continue
        fv  := reflect.struct_field_value(value, field)
        key := prefix == "" ? field.name : fmt.tprintf("%s.%s", prefix, field.name)
        if type_is_struct(fv.id) {
            serialize_struct(b, fv, key)
            continue
        }
        fmt.sbprintf(b, "%s = ", key)
        serialize_value(b, fv)
        strings.write_byte(b, '\n')
    }
}

// True for genuine structs (recursed into), false for the aggregate leaves entities use — vectors
// (Array), quaternions, sbuf (fixed dynamic array). Bases through named/distinct types.
type_is_struct :: proc(id: typeid) -> bool {
    _, ok := reflect.type_info_base(type_info_of(id)).variant.(runtime.Type_Info_Struct)
    return ok
}

// Resolves a dotted field path ("transform.position") within struct `root`, descending through
// nested struct fields. Returns an `any` aliasing the live leaf slot (so writes through it hit
// `root`), or ok=false if any segment doesn't name a field. Shared by scene load and the Lua
// entity accessors.
struct_field_by_path :: proc(root: any, path: string) -> (v: any, ok: bool) {
    cur  := root
    rest := path
    for {
        seg, tail := rest, ""
        if d := strings.index_byte(rest, '.'); d >= 0 {
            seg, tail = rest[:d], rest[d + 1:]
        }
        found := false
        for i in 0 ..< reflect.struct_field_count(cur.id) {
            sf := reflect.struct_field_at(cur.id, i)
            if sf.name == seg {
                cur, found = reflect.struct_field_value(cur, sf), true
                break
            }
        }
        if !found do return nil, false
        if tail == "" do return cur, true
        rest = tail
    }
}

@(private="file")
serialize_value :: proc(b: ^strings.Builder, v: any) {
    #partial switch info in type_info_of(v.id).variant {
    case runtime.Type_Info_String:
        strings.write_string(b, v.(string))
    case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:   // sbuf: inline string buffer (any size)
        if s, ok := sbuf_any_str(v); ok do strings.write_string(b, s)
    case runtime.Type_Info_Boolean:
        strings.write_string(b, v.(bool) ? "true" : "false")
    case runtime.Type_Info_Float:
        fmt.sbprintf(b, "%v", v.(f32))
    case runtime.Type_Info_Quaternion:
        a := transmute([4]f32)v.(quat)
        fmt.sbprintf(b, "%v, %v, %v, %v", a[0], a[1], a[2], a[3])
    case runtime.Type_Info_Bit_Set:   // flags: comma-separated set member names (u64-backed, per convention)
        bits := (^u64)(v.data)^
        names  := reflect.enum_field_names(info.elem.id)
        values := reflect.enum_field_values(info.elem.id)
        first := true
        for name, k in names {
            if bits & (u64(1) << u64(i64(values[k]) - info.lower)) != 0 {
                if !first do strings.write_string(b, ", ")
                strings.write_string(b, name)
                first = false
            }
        }
    case runtime.Type_Info_Integer:
        fmt.sbprintf(b, "%v", v)
    case runtime.Type_Info_Named:   // enums arrive as a named type wrapping an enum base
        #partial switch _ in info.base.variant {
        case runtime.Type_Info_Enum:
            if name, ok := reflect.enum_name_from_value_any(v); ok do strings.write_string(b, name)
        case runtime.Type_Info_Integer:
            fmt.sbprintf(b, "%v", v)
        }
    case runtime.Type_Info_Array:
        arr := cast([^]f32)v.data
        for k in 0..<info.count {
            if k > 0 do strings.write_string(b, ", ")
            fmt.sbprintf(b, "%v", arr[k])
        }
    }
}

// Parses a text value into a typed field (via `any`). Vectors/quaternions are comma-separated.
// String fields are cloned with `allocator` — the arena of the world the value lands in — so they
// outlive the temp read buffer and are freed with that world.
deserialize_value :: proc(dst: any, text: string, allocator: runtime.Allocator) {
    #partial switch info in type_info_of(dst.id).variant {
    case runtime.Type_Info_String:
        // (Entity.model is additionally re-interned into the asset arena after load; see scene_load.)
        (^string)(dst.data)^ = strings.clone(text, allocator)
    case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:   // sbuf: inline, copies the bytes in (any size)
        sbuf_any_set(dst, text)
    case runtime.Type_Info_Boolean:
        (^bool)(dst.data)^ = text == "true"
    case runtime.Type_Info_Float:
        (^f32)(dst.data)^ = strconv.parse_f32(text) or_else 0
    case runtime.Type_Info_Quaternion:
        parts := strings.split(text, ",", context.temp_allocator)
        if len(parts) >= 4 {
            a: [4]f32
            for k in 0..<4 do a[k] = strconv.parse_f32(strings.trim_space(parts[k])) or_else 0
            (^quat)(dst.data)^ = transmute(quat)a
        }
    case runtime.Type_Info_Bit_Set:   // flags: comma-separated set member names (u64-backed, per convention)
        bits: u64
        for tok in strings.split(text, ",", context.temp_allocator) {
            name := strings.trim_space(tok)
            if name == "" do continue
            if val, ok := reflect.enum_from_name_any(info.elem.id, name); ok {
                bits |= u64(1) << u64(i64(val) - info.lower)
            }
        }
        (^u64)(dst.data)^ = bits
    case runtime.Type_Info_Integer:
        write_int_bits(dst, strconv.parse_i64(strings.trim_space(text)) or_else 0)
    case runtime.Type_Info_Named:   // enums arrive as a named type wrapping an enum base
        #partial switch _ in info.base.variant {
        case runtime.Type_Info_Enum:
            if val, ok := reflect.enum_from_name_any(dst.id, strings.trim_space(text)); ok {
                write_int_bits(dst, i64(val))
            }
        case runtime.Type_Info_Integer:
            write_int_bits(dst, strconv.parse_i64(strings.trim_space(text)) or_else 0)
        }
    case runtime.Type_Info_Array:
        parts := strings.split(text, ",", context.temp_allocator)
        arr := cast([^]f32)dst.data
        for k in 0..<min(len(parts), info.count) {
            arr[k] = strconv.parse_f32(strings.trim_space(parts[k])) or_else 0
        }
    }
}

// Writes an integer value into a field of any integer width (1/2/4/8 bytes). Writing the
// unsigned pattern is correct for signed fields too (same low bits). Shared by the Integer
// and enum deserialize cases.
@(private = "file")
write_int_bits :: proc(dst: any, n: i64) {
    switch type_info_of(dst.id).size {
    case 1: (^u8)(dst.data)^  = u8(n)
    case 2: (^u16)(dst.data)^ = u16(n)
    case 4: (^u32)(dst.data)^ = u32(n)
    case 8: (^u64)(dst.data)^ = u64(n)
    }
}

// Reads the `key = value` lines of the `[section]` sections in INI `text` into the struct `root`
// (dotted keys reach nested fields). Unknown keys are skipped, so missing fields keep their values.
ini_read_section :: proc(text: string, section: string, root: any, allocator: runtime.Allocator) {
    in_section := false
    txt := text
    for line in strings.split_lines_iterator(&txt) {
        t := strings.trim_space(line)
        if len(t) == 0 || t[0] == '#' || t[0] == ';' do continue
        if t[0] == '[' && t[len(t) - 1] == ']' {
            in_section = strings.trim_space(t[1:len(t) - 1]) == section
            continue
        }
        if !in_section do continue
        eq := strings.index_byte(t, '=')
        if eq < 0 do continue
        if v, ok := struct_field_by_path(root, strings.trim_space(t[:eq])); ok {
            deserialize_value(v, strings.trim_space(t[eq + 1:]), allocator)
        }
    }
}

// The value for `key` in clipboard-style text: from its `key = value` line if the text is INI-style
// (a copied [entity] block, or any key = value lines), or the text itself if it's one bare line
// with no `=` (e.g. a pasted asset key). ok=false if neither applies. Returned value slices `text`.
text_field_value :: proc(text: string, key: string) -> (value: string, ok: bool) {
    trimmed := strings.trim_space(text)
    if trimmed == "" do return "", false
    if strings.index_byte(trimmed, '=') < 0 && strings.index_byte(trimmed, '\n') < 0 do return trimmed, true

    txt := trimmed
    for line in strings.split_lines_iterator(&txt) {
        l := strings.trim_space(line)
        eq := strings.index_byte(l, '=')
        if eq < 0 || len(l) == 0 || l[0] == '#' || l[0] == ';' || l[0] == '[' do continue
        if strings.trim_space(l[:eq]) == key do return strings.trim_space(l[eq + 1:]), true
    }
    return "", false
}

// True if the comma-separated backtick `tag` string contains `name` (e.g. "noserialize",
// "identity", "placement"). Used by serialize_struct and the Entity field router.
field_has_tag :: proc(tag: reflect.Struct_Tag, name: string) -> bool {
    for t in strings.split(string(tag), ",", context.temp_allocator) {
        if strings.trim_space(t) == name do return true
    }
    return false
}
