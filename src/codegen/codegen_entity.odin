package codegen

import "core:os"
import "core:fmt"
import "core:log"
import "core:strings"

// Emits src/gen_entity.odin from entity_schema.ini. Everything the runtime needs about the
// schema is baked in here at build time, so the shipped game never reads the INI:
//   - the Entity struct (fields in order, with backtick `tags`), plus an enum/bit_set for each
//     [enum]/[flags] and a struct for each [struct];
//   - entity_apply_defaults(): literal assignments from each field/member `default`;
//   - entity_field_label / entity_flag_item_label / entity_struct_member_label: the EN/ZH labels
//     as static switches (the inspector's localized names).
// The INI is now purely an authoring artifact — only the in-engine schema editor reads/writes it.

ENTITY_SCHEMA_PATH :: "entity_schema.ini"
ENTITY_GEN_PATH    :: "src/gen_entity.odin"

@(private = "file")
Schema_Field :: struct { name, type, tags, section, en, zh, default, note: string }
@(private = "file")
Schema_Member :: struct { name, en, zh, note: string }   // enum / flags value
@(private = "file")
Schema_Type :: struct { name, note: string, is_flags: bool, members: [dynamic]Schema_Member }
@(private = "file")
Schema_SMember :: struct { name, type, en, zh, default, note: string }   // struct field
@(private = "file")
Schema_Struct :: struct { name, note: string, members: [dynamic]Schema_SMember }

generate_entity :: proc() {
    data, rerr := os.read_entire_file(ENTITY_SCHEMA_PATH, context.temp_allocator)
    if rerr != nil {
        log.errorf("Entity codegen: cannot read %v: %v", ENTITY_SCHEMA_PATH, rerr)
        return
    }

    fields:  [dynamic]Schema_Field
    types:   [dynamic]Schema_Type     // [enum.*] and [flags.*] type declarations
    structs: [dynamic]Schema_Struct   // [struct.*] type declarations

    // Which record subsequent `key = value` lines apply to.
    Target :: enum { None, Field, Enum, Enum_Member, Struct, Struct_Member }
    target := Target.None

    text := string(data)
    for raw in strings.split_lines_iterator(&text) {
        line := strings.trim_space(raw)
        if len(line) == 0 || line[0] == '#' || line[0] == ';' do continue

        if line[0] == '[' && line[len(line) - 1] == ']' {
            parts := strings.split(strings.trim_space(line[1:len(line) - 1]), ".", context.temp_allocator)
            kind := parts[0]
            switch {
            case kind == "field" && len(parts) == 2:
                append(&fields, Schema_Field{name = strings.clone(parts[1])})
                target = .Field
            case (kind == "enum" || kind == "flags") && len(parts) == 2:
                append(&types, Schema_Type{name = strings.clone(parts[1]), is_flags = kind == "flags"})
                target = .Enum
            case (kind == "enum" || kind == "flags") && len(parts) == 3:
                if len(types) > 0 { append(&types[len(types) - 1].members, Schema_Member{name = strings.clone(parts[2])}); target = .Enum_Member } else { target = .None }
            case kind == "struct" && len(parts) == 2:
                append(&structs, Schema_Struct{name = strings.clone(parts[1])})
                target = .Struct
            case kind == "struct" && len(parts) == 3:
                if len(structs) > 0 { append(&structs[len(structs) - 1].members, Schema_SMember{name = strings.clone(parts[2])}); target = .Struct_Member } else { target = .None }
            case:
                target = .None
            }
            continue
        }

        eq := strings.index_byte(line, '=')
        if eq < 0 do continue
        key := strings.trim_space(line[:eq])
        val := strings.trim_space(line[eq + 1:])

        switch target {
        case .None:
        case .Field:
            f := &fields[len(fields) - 1]
            switch key {
            case "type":    f.type    = strings.clone(val)
            case "tags":    f.tags    = strings.clone(val)
            case "section": f.section = strings.clone(val)
            case "en":      f.en      = strings.clone(val)
            case "zh":      f.zh      = strings.clone(val)
            case "default": f.default = strings.clone(val)
            case "note":    f.note    = strings.clone(val)
            }
        case .Enum:
            if key == "note" do types[len(types) - 1].note = strings.clone(val)
        case .Struct:
            if key == "note" do structs[len(structs) - 1].note = strings.clone(val)
        case .Enum_Member:
            m := &types[len(types) - 1].members[len(types[len(types) - 1].members) - 1]
            switch key {
            case "en":   m.en   = strings.clone(val)
            case "zh":   m.zh   = strings.clone(val)
            case "note": m.note = strings.clone(val)
            }
        case .Struct_Member:
            m := &structs[len(structs) - 1].members[len(structs[len(structs) - 1].members) - 1]
            switch key {
            case "type":    m.type    = strings.clone(val)
            case "en":      m.en      = strings.clone(val)
            case "zh":      m.zh      = strings.clone(val)
            case "default": m.default = strings.clone(val)
            case "note":    m.note    = strings.clone(val)
            }
        }
    }

    // Register generated type names so the Lua binding pass can marshal enum/flag fields as
    // integers (a flags field's type is the bit_set alias `<Name>s`).
    for t in types {
        if t.is_flags {
            codegen.flag_types[strings.concatenate({t.name, "s"})] = true
        } else {
            codegen.enum_types[t.name] = true
        }
    }

    sb: strings.Builder
    strings.builder_init(&sb)
    fmt.sbprintln(&sb, "// AUTO GENERATED. DO NOT EDIT — edit entity_schema.ini instead.")
    fmt.sbprintln(&sb, "")
    fmt.sbprintln(&sb, "package blimp")
    fmt.sbprintln(&sb, "")

    // ---- Entity struct. A field's `section` is emitted as a `section:<Member>` tag, which the inspector reads. ----
    fmt.sbprintln(&sb, "Entity :: struct {")
    for f in fields {
        _emit_note(&sb, f.note, "    ")
        tags := f.tags
        if f.section != "" do tags = fmt.tprintf("%s%ssection:%s", tags, tags != "" ? ", " : "", f.section)
        if len(tags) > 0 {
            fmt.sbprintfln(&sb, "    %v: %v `%v`,", f.name, _odin_field_type(f.type), tags)
        } else {
            fmt.sbprintfln(&sb, "    %v: %v,", f.name, _odin_field_type(f.type))
        }
    }
    fmt.sbprintln(&sb, "}")
    fmt.sbprintln(&sb, "")

    // ---- Composite types. Package-scope decls are order-independent in Odin, so a struct may
    // reference another declared later (a by-value cycle is a compile error, by design). ----
    for s in structs {
        _emit_note(&sb, s.note, "")
        fmt.sbprintfln(&sb, "%v :: struct {{", s.name)
        for m in s.members {
            _emit_note(&sb, m.note, "    ")
            fmt.sbprintfln(&sb, "    %v: %v,", m.name, _odin_field_type(m.type))
        }
        fmt.sbprintln(&sb, "}")
        fmt.sbprintln(&sb, "")
    }

    for t in types {
        _emit_note(&sb, t.note, "")
        fmt.sbprintfln(&sb, "%v :: enum u64 {{", t.name)
        for m in t.members {
            _emit_note(&sb, m.note, "    ")
            fmt.sbprintfln(&sb, "    %v,", m.name)
        }
        fmt.sbprintln(&sb, "}")
        if t.is_flags {
            fmt.sbprintfln(&sb, "%vs :: bit_set[%v; u64]", t.name, t.name)
        }
        fmt.sbprintln(&sb, "")
    }

    _emit_apply_defaults(&sb, fields[:], structs[:])
    _emit_field_labels(&sb, fields[:])
    _emit_flag_labels(&sb, types[:])
    _emit_struct_labels(&sb, structs[:])

    write_generated(ENTITY_GEN_PATH, strings.to_string(sb))
}

// A schema `note` as `//` comment lines above the declaration, wrapped at about 100 columns.
@(private = "file")
_emit_note :: proc(sb: ^strings.Builder, note, indent: string) {
    if note == "" do return
    line := 0
    fmt.sbprintf(sb, "%s//", indent)
    for word in strings.fields(note, context.temp_allocator) {
        if line > 0 && line + 1 + len(word) > 100 - len(indent) {
            fmt.sbprintf(sb, "\n%s//", indent)
            line = 0
        }
        fmt.sbprintf(sb, " %s", word)
        line += 1 + len(word)
    }
    fmt.sbprintln(sb)
}

// ---- entity_apply_defaults: literal assignments ----

@(private = "file")
_emit_apply_defaults :: proc(sb: ^strings.Builder, fields: []Schema_Field, structs: []Schema_Struct) {
    fmt.sbprintln(sb, "// Applies each schema `default` to a fresh entity (fields with no default keep zero).")
    fmt.sbprintln(sb, "entity_apply_defaults :: proc(e: ^Entity) {")
    for f in fields {
        _emit_default_assign(sb, fmt.tprintf("e.%s", f.name), f.type, f.default, structs)
    }
    fmt.sbprintln(sb, "}")
    fmt.sbprintln(sb, "")
}

// Emits `<lhs> = <literal>` for a scalar/enum/flags default, or recurses into a struct field's
// members. No-op when there is no default and it isn't a struct.
@(private = "file")
_emit_default_assign :: proc(sb: ^strings.Builder, lhs, schema_type, def: string, structs: []Schema_Struct) {
    if strings.has_prefix(schema_type, "struct.") {
        name := schema_type[len("struct."):]
        for s in structs do if s.name == name {
            for m in s.members do _emit_default_assign(sb, fmt.tprintf("%s.%s", lhs, m.name), m.type, m.default, structs)
            return
        }
        return
    }
    if def == "" do return
    if strings.has_prefix(schema_type, "sbuf") {   // sbuf64 / sbuf128 / sbuf256: set via the inline-buffer helper
        fmt.sbprintfln(sb, "    sbuf_set(&%s, \"%s\")", lhs, def)
        return
    }
    if lit, ok := _default_literal(schema_type, def); ok {
        fmt.sbprintfln(sb, "    %s = %s", lhs, lit)
    }
}

// The Odin literal for a schema type + default text (e.g. vec3 "0, 0, 0" -> "{0, 0, 0}").
@(private = "file")
_default_literal :: proc(schema_type, def: string) -> (string, bool) {
    switch schema_type {
    case "f32", "f64", "i32", "u32", "i64", "u64", "int", "bool":
        return def, true
    case "string":
        return fmt.tprintf("\"%s\"", def), true
    case "vec2", "vec3", "vec4":
        return fmt.tprintf("{{%s}}", def), true
    case "quat":
        return fmt.tprintf("transmute(quat)[4]f32{{%s}}", def), true
    }
    if strings.has_prefix(schema_type, "enum.")  do return fmt.tprintf(".%s", def), true
    if strings.has_prefix(schema_type, "flags.") do return _flags_literal(def), true
    return "", false
}

// "Static, Renderable" -> "{.Static, .Renderable}" (a bit_set literal).
@(private = "file")
_flags_literal :: proc(def: string) -> string {
    b: strings.Builder
    strings.builder_init(&b, context.temp_allocator)
    strings.write_string(&b, "{")
    first := true
    for part in strings.split(def, ",", context.temp_allocator) {
        m := strings.trim_space(part)
        if m == "" do continue
        if !first do strings.write_string(&b, ", ")
        strings.write_byte(&b, '.')
        strings.write_string(&b, m)
        first = false
    }
    strings.write_string(&b, "}")
    return strings.to_string(b)
}

// ---- label switches (localized inspector names) ----

@(private = "file")
_emit_field_labels :: proc(sb: ^strings.Builder, fields: []Schema_Field) {
    // Every language at once, for the inspector's search (a field is found by either name).
    fmt.sbprintln(sb, "// A field's label in every language (empty where it has none).")
    fmt.sbprintln(sb, "entity_field_labels :: proc(name: string) -> (l: [Lang]string) {")
    fmt.sbprintln(sb, "    switch name {")
    for f in fields do if lit, ok := _lang_literal(f.en, f.zh); ok {
        fmt.sbprintfln(sb, "    case \"%s\": l = %s", f.name, lit)
    }
    fmt.sbprintln(sb, "    }")
    fmt.sbprintln(sb, "    return")
    fmt.sbprintln(sb, "}")
    fmt.sbprintln(sb, "")
    fmt.sbprintln(sb, "// Localized field label for the current language; ok=false if none.")
    fmt.sbprintln(sb, "entity_field_label :: proc(name: string) -> (string, bool) {")
    fmt.sbprintln(sb, "    s := entity_field_labels(name)[loc_lang]")
    fmt.sbprintln(sb, "    return s, s != \"\"")
    fmt.sbprintln(sb, "}")
    fmt.sbprintln(sb, "")
}

@(private = "file")
_emit_flag_labels :: proc(sb: ^strings.Builder, types: []Schema_Type) {
    // Every language at once, for the inspector's search (a value is found by either name).
    fmt.sbprintln(sb, "// An enum/flags member's label in every language, keyed on the type name (empty where it has none).")
    fmt.sbprintln(sb, "entity_flag_item_labels :: proc(enum_type: string, member: string) -> (l: [Lang]string) {")
    fmt.sbprintln(sb, "    switch enum_type {")
    for t in types {
        has := false
        for m in t.members do if _, ok := _lang_literal(m.en, m.zh); ok { has = true; break }
        if !has do continue
        fmt.sbprintfln(sb, "    case \"%s\":", t.name)
        fmt.sbprintln(sb, "        switch member {")
        for m in t.members do if lit, ok := _lang_literal(m.en, m.zh); ok {
            fmt.sbprintfln(sb, "        case \"%s\": l = %s", m.name, lit)
        }
        fmt.sbprintln(sb, "        }")
    }
    fmt.sbprintln(sb, "    }")
    fmt.sbprintln(sb, "    return")
    fmt.sbprintln(sb, "}")
    fmt.sbprintln(sb, "")
    fmt.sbprintln(sb, "// Localized enum/flags member label, keyed on the type name; ok=false if none.")
    fmt.sbprintln(sb, "entity_flag_item_label :: proc(enum_type: string, member: string) -> (string, bool) {")
    fmt.sbprintln(sb, "    s := entity_flag_item_labels(enum_type, member)[loc_lang]")
    fmt.sbprintln(sb, "    return s, s != \"\"")
    fmt.sbprintln(sb, "}")
    fmt.sbprintln(sb, "")
}

@(private = "file")
_emit_struct_labels :: proc(sb: ^strings.Builder, structs: []Schema_Struct) {
    fmt.sbprintln(sb, "// Localized struct member label, keyed on the struct type name; ok=false if none.")
    fmt.sbprintln(sb, "entity_struct_member_label :: proc(struct_type: string, member: string) -> (string, bool) {")
    fmt.sbprintln(sb, "    l: [Lang]string")
    fmt.sbprintln(sb, "    switch struct_type {")
    for s in structs {
        has := false
        for m in s.members do if _, ok := _lang_literal(m.en, m.zh); ok { has = true; break }
        if !has do continue
        fmt.sbprintfln(sb, "    case \"%s\":", s.name)
        fmt.sbprintln(sb, "        switch member {")
        for m in s.members do if lit, ok := _lang_literal(m.en, m.zh); ok {
            fmt.sbprintfln(sb, "        case \"%s\": l = %s", m.name, lit)
        }
        fmt.sbprintln(sb, "        }")
    }
    fmt.sbprintln(sb, "    }")
    fmt.sbprintln(sb, "    s := l[loc_lang]")
    fmt.sbprintln(sb, "    return s, s != \"\"")
    fmt.sbprintln(sb, "}")
    fmt.sbprintln(sb, "")
}

// A `[Lang]string` literal with only the non-empty columns, e.g. {.EN = "Name", .ZH = "名称"};
// ok=false when both are empty (so callers can omit the case entirely).
@(private = "file")
_lang_literal :: proc(en, zh: string) -> (string, bool) {
    if en == "" && zh == "" do return "", false
    b: strings.Builder
    strings.builder_init(&b, context.temp_allocator)
    strings.write_string(&b, "{")
    first := true
    if en != "" { fmt.sbprintf(&b, ".EN = \"%s\"", en); first = false }
    if zh != "" { if !first do strings.write_string(&b, ", "); fmt.sbprintf(&b, ".ZH = \"%s\"", zh) }
    strings.write_string(&b, "}")
    return strings.to_string(b), true
}

// Maps a schema type string to the Odin type: `flags.X` -> `Xs` (bit_set alias), `enum.X` -> `X`,
// `struct.X` -> `X`, and a scalar (`f32`, `vec3`, …) passes through unchanged.
@(private = "file")
_odin_field_type :: proc(schema_type: string) -> string {
    if strings.has_prefix(schema_type, "flags.")  do return strings.concatenate({schema_type[len("flags."):], "s"}, context.temp_allocator)
    if strings.has_prefix(schema_type, "enum.")   do return schema_type[len("enum."):]
    if strings.has_prefix(schema_type, "struct.") do return schema_type[len("struct."):]
    return schema_type
}
