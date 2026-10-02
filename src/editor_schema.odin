package blimp

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import vmem "core:mem/virtual"

// Editor-side model of entity_schema.ini: a fully-editable, in-memory document loaded from the
// INI, mutated by the schema editor window (ui_schema_editor.odin), and written back. This is the
// only runtime code that touches the INI — labels/defaults reach the game via codegen (baked into
// gen_entity.odin), not a runtime read. All text is held in fixed Edit_Buf buffers because
// odin-imgui's InputText is buffer-based; the only heap allocations are the dynamic arrays,
// owned by `arena`.

// The schema file, edited here and consumed by codegen at build time.
ENTITY_SCHEMA_PATH :: "entity_schema.ini"

EDIT_BUF_LEN :: 128

// A fixed, NUL-terminated text buffer suitable for direct use with im.InputText.
Edit_Buf :: struct {
    data: [EDIT_BUF_LEN]u8,
}

edit_buf_set :: proc(b: ^Edit_Buf, s: string) {
    n := min(len(s), EDIT_BUF_LEN - 1)
    copy(b.data[:], s[:n])
    b.data[n] = 0
}

// The current text, up to the NUL terminator.
edit_buf_str :: proc(b: ^Edit_Buf) -> string {
    return string(cstring(raw_data(b.data[:])))
}

Doc_Field :: struct {
    id:      Edit_Buf,   // section id = struct field name (stable; scenes serialize by this)
    type:    Edit_Buf,   // "f32", "flags.EntityBasicStaticFlag", "enum.Team", "struct.Foo", …
    en:      Edit_Buf,
    zh:      Edit_Buf,
    default: Edit_Buf,
    tags:    Edit_Buf,   // preserved verbatim (e.g. "hidden, noserialize")
    builtin: bool,       // engine-required: locked in the editor
}

Doc_Item :: struct {
    id:      Edit_Buf,   // enum member / struct field identifier
    type:    Edit_Buf,   // struct members only ("f32", "vec3", "struct.X", …); unused for enum/flags
    en:      Edit_Buf,
    zh:      Edit_Buf,
    default: Edit_Buf,   // struct members only
}

Doc_Type_Kind :: enum { Enum, Flags, Struct }

Doc_Type :: struct {
    name:    Edit_Buf,
    kind:    Doc_Type_Kind,
    builtin: bool,
    members: [dynamic]Doc_Item,   // enum/flags: id+en+zh; struct: id+type+en+zh+default
}

Schema_Doc :: struct {
    fields: [dynamic]Doc_Field,
    types:  [dynamic]Doc_Type,
    arena:  vmem.Arena,
    loaded: bool,
}
schema_doc: Schema_Doc

// Canonical header written on save (the hand-authored comments aren't round-tripped).
@(private = "file")
SCHEMA_HEADER ::
`# Entity schema — the source of truth for the Entity struct.
# Build time: codegen emits src/gen_entity.odin. Run time: entity_schema.odin loads
# labels/defaults. Edited by the in-engine schema editor. Section order = struct/member order.
#
# Grammar — INI with TOML-style dotted sections. Every declaration is a [qualified.name]
# section followed by "key = value" attribute lines:
#
#   [field.<id>]                 type / en / zh / default / tags / builtin
#   [enum.<T>] / [flags.<T>]     a type;  [enum.<T>.<member>]   -> en / zh
#   [struct.<T>]                 a type;  [struct.<T>.<member>] -> type / en / zh / default
#
# Types: scalars (bool, i32, u32, f32, string, vec2, vec3, vec4, quat), owned inline text
# (sbuf64 / sbuf128 / sbuf256), the builtin-only Entity_Handle, and qualified refs to authored
# types: enum.<T> / flags.<T> /
# struct.<T>. A dot means the same thing in a header and in a type = reference.
`

// A category separator comment, e.g.  #================ Fields ================
@(private = "file")
_doc_banner :: proc(b: ^strings.Builder, title: string) {
    fmt.sbprintfln(b, "\n\n#================================ %s ================================", title)
}

// The INI keyword for a type kind ("enum" | "flags" | "struct"), used in headers and type refs.
doc_kind_word :: proc(kind: Doc_Type_Kind) -> string {
    switch kind {
    case .Flags:  return "flags"
    case .Struct: return "struct"
    case .Enum:   return "enum"
    }
    return "enum"
}

schema_doc_load :: proc() {
    if !schema_doc.loaded {
        if err := vmem.arena_init_growing(&schema_doc.arena); err != nil {
            log.panicf("Failed to init schema doc arena: %v", err)
        }
        schema_doc.loaded = true
    } else {
        vmem.arena_free_all(&schema_doc.arena)
    }
    a := vmem.arena_allocator(&schema_doc.arena)
    schema_doc.fields = make([dynamic]Doc_Field, a)
    schema_doc.types  = make([dynamic]Doc_Type, a)

    data, rerr := os.read_entire_file(ENTITY_SCHEMA_PATH, context.temp_allocator)
    if rerr != nil {
        log.errorf("schema_doc: cannot read %v: %v", ENTITY_SCHEMA_PATH, rerr)
        return
    }

    // Which record subsequent `key = value` lines apply to.
    Target :: enum { None, Field, Type, Member }
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
                f: Doc_Field
                edit_buf_set(&f.id, parts[1])
                append(&schema_doc.fields, f)
                target = .Field
            case (kind == "enum" || kind == "flags" || kind == "struct") && len(parts) == 2:
                t: Doc_Type
                edit_buf_set(&t.name, parts[1])
                switch kind {
                case "flags":  t.kind = .Flags
                case "struct": t.kind = .Struct
                case:          t.kind = .Enum
                }
                t.members = make([dynamic]Doc_Item, a)
                append(&schema_doc.types, t)
                target = .Type
            case (kind == "enum" || kind == "flags" || kind == "struct") && len(parts) == 3:
                if len(schema_doc.types) > 0 {
                    item: Doc_Item
                    edit_buf_set(&item.id, parts[2])
                    append(&schema_doc.types[len(schema_doc.types) - 1].members, item)
                    target = .Member
                } else {
                    target = .None
                }
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
            f := &schema_doc.fields[len(schema_doc.fields) - 1]
            switch key {
            case "type":    edit_buf_set(&f.type, val)
            case "en":      edit_buf_set(&f.en, val)
            case "zh":      edit_buf_set(&f.zh, val)
            case "default": edit_buf_set(&f.default, val)
            case "tags":    edit_buf_set(&f.tags, val)
            case "builtin": f.builtin = val == "true"
            }
        case .Type:
            t := &schema_doc.types[len(schema_doc.types) - 1]
            if key == "builtin" do t.builtin = val == "true"
        case .Member:
            t := &schema_doc.types[len(schema_doc.types) - 1]
            m := &t.members[len(t.members) - 1]
            switch key {
            case "type":    edit_buf_set(&m.type, val)
            case "en":      edit_buf_set(&m.en, val)
            case "zh":      edit_buf_set(&m.zh, val)
            case "default": edit_buf_set(&m.default, val)
            }
        }
    }
}

schema_doc_save :: proc(path: string) -> bool {
    b: strings.Builder
    strings.builder_init(&b, context.temp_allocator)

    strings.write_string(&b, SCHEMA_HEADER)

    _doc_banner(&b, "Fields")
    for &f in schema_doc.fields {
        fmt.sbprintfln(&b, "\n[field.%s]", edit_buf_str(&f.id))
        _doc_write_kv(&b, "type", edit_buf_str(&f.type))
        if f.builtin do _doc_write_kv(&b, "builtin", "true")
        _doc_write_kv_opt(&b, "tags", edit_buf_str(&f.tags))
        _doc_write_kv_opt(&b, "en", edit_buf_str(&f.en))
        _doc_write_kv_opt(&b, "zh", edit_buf_str(&f.zh))
        _doc_write_kv_opt(&b, "default", edit_buf_str(&f.default))
    }

    // Types grouped by kind, each group under its own banner (skipped when empty). Grouping is a
    // save-time layout only — codegen/runtime don't care about type declaration order.
    for group in ([?]struct{ kind: Doc_Type_Kind, title: string }{
        {.Enum, "Enums"}, {.Flags, "Flags"}, {.Struct, "Structs"},
    }) {
        has_any := false
        for &t in schema_doc.types do if t.kind == group.kind { has_any = true; break }
        if !has_any do continue

        _doc_banner(&b, group.title)
        for &t in schema_doc.types {
            if t.kind != group.kind do continue
            kind := doc_kind_word(t.kind)
            name := edit_buf_str(&t.name)
            fmt.sbprintfln(&b, "\n[%s.%s]", kind, name)
            if t.builtin do _doc_write_kv(&b, "builtin", "true")
            for &m in t.members {
                fmt.sbprintfln(&b, "\n[%s.%s.%s]", kind, name, edit_buf_str(&m.id))
                if t.kind == .Struct do _doc_write_kv(&b, "type", edit_buf_str(&m.type))
                _doc_write_kv_opt(&b, "en", edit_buf_str(&m.en))
                _doc_write_kv_opt(&b, "zh", edit_buf_str(&m.zh))
                if t.kind == .Struct do _doc_write_kv_opt(&b, "default", edit_buf_str(&m.default))
            }
        }
    }

    if err := os.write_entire_file(path, strings.to_string(b)); err != nil {
        log.errorf("schema_doc: failed to write %v: %v", path, err)
        return false
    }
    log.infof("schema_doc: wrote %v (%v fields, %v types)", path, len(schema_doc.fields), len(schema_doc.types))
    return true
}

// Validates the document. Returns ok plus a human-readable message on the first problem.
schema_doc_validate :: proc() -> (ok: bool, msg: string) {
    for &f, i in schema_doc.fields {
        id := edit_buf_str(&f.id)
        if id == "" do return false, "a field has an empty id"
        for &g, j in schema_doc.fields do if j != i && edit_buf_str(&g.id) == id {
            return false, strings.concatenate({"duplicate field id: ", id}, context.temp_allocator)
        }
        t := edit_buf_str(&f.type)
        if !_doc_type_resolves(t) {
            return false, strings.concatenate({"field '", id, "' has unknown type: ", t}, context.temp_allocator)
        }
    }
    for &t, i in schema_doc.types {
        name := edit_buf_str(&t.name)
        if name == "" do return false, "a type has an empty name"
        for &u, j in schema_doc.types do if j != i && edit_buf_str(&u.name) == name {
            return false, strings.concatenate({"duplicate type name: ", name}, context.temp_allocator)
        }
        for &m, mi in t.members {
            mid := edit_buf_str(&m.id)
            if mid == "" do return false, strings.concatenate({"type '", name, "' has an empty member"}, context.temp_allocator)
            for &n, mj in t.members do if mj != mi && edit_buf_str(&n.id) == mid {
                return false, strings.concatenate({"type '", name, "' has duplicate member: ", mid}, context.temp_allocator)
            }
            if t.kind == .Struct {
                mtype := edit_buf_str(&m.type)
                if !_doc_type_resolves(mtype) {
                    return false, strings.concatenate({"struct '", name, "' member '", mid, "' has unknown type: ", mtype}, context.temp_allocator)
                }
                // A struct that contains itself by value is infinite-size (a compile error).
                if mtype == strings.concatenate({"struct.", name}, context.temp_allocator) {
                    return false, strings.concatenate({"struct '", name, "' cannot contain itself: ", mid}, context.temp_allocator)
                }
            }
        }
    }
    return true, ""
}

/* ------------------------------ helpers ------------------------------ */

// All scalar types accepted by validation (includes the builtin-only Entity_Handle).
SCHEMA_SCALAR_TYPES :: [?]string{"bool", "i32", "u32", "f32", "string", "sbuf64", "sbuf128", "sbuf256", "vec2", "vec3", "vec4", "quat", "Entity_Handle"}
// Types offered in the editor's dropdown for user-created fields (Lua-marshalable; authored
// enum./flags./struct. types are appended at runtime).
SCHEMA_USER_TYPES :: [?]string{"bool", "i32", "u32", "f32", "sbuf64", "sbuf128", "sbuf256", "string", "vec2", "vec3", "vec4", "quat"}

@(private = "file")
_doc_type_resolves :: proc(t: string) -> bool {
    for s in SCHEMA_SCALAR_TYPES do if s == t do return true
    // A qualified ref (enum.X / flags.X / struct.X) must name an authored type of the matching kind.
    dot := strings.index_byte(t, '.')
    if dot < 0 do return false
    want: Doc_Type_Kind
    switch t[:dot] {
    case "flags":  want = .Flags
    case "enum":   want = .Enum
    case "struct": want = .Struct
    case:          return false
    }
    name := t[dot + 1:]
    for &dt in schema_doc.types {
        if edit_buf_str(&dt.name) == name && dt.kind == want do return true
    }
    return false
}

// Writes `key = val`, padding the key to a fixed column so attributes line up (widest key is
// "builtin"/"default" = 7).
@(private = "file")
_doc_write_kv :: proc(b: ^strings.Builder, key, val: string) {
    strings.write_string(b, key)
    for _ in len(key) ..< 7 do strings.write_byte(b, ' ')
    strings.write_string(b, " = ")
    strings.write_string(b, val)
    strings.write_byte(b, '\n')
}

@(private = "file")
_doc_write_kv_opt :: proc(b: ^strings.Builder, key, val: string) {
    if val != "" do _doc_write_kv(b, key, val)
}
