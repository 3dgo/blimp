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

EDIT_BUF_LEN :: 512   // a note can run to a few sentences

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
    flags:   [len(SCHEMA_FLAG_TAGS)]bool,   // which of SCHEMA_FLAG_TAGS it has
    widget:  Edit_Buf,   // a schema_widgets name, "" = the type's default widget
    section: Edit_Buf,   // inspector section: a member of enum EntitySection, "" = top, above the sections
    note:    Edit_Buf,   // what it's for, one line: written beside the field in gen_entity.odin
    builtin: bool,       // engine-required: locked in the editor
}

Doc_Item :: struct {
    id:      Edit_Buf,   // enum member / struct field identifier
    type:    Edit_Buf,   // struct members only ("f32", "vec3", "struct.X", …); unused for enum/flags
    en:      Edit_Buf,
    zh:      Edit_Buf,
    default: Edit_Buf,   // struct members only
    note:    Edit_Buf,
}

Doc_Type_Kind :: enum { Enum, Flags, Struct }

Doc_Type :: struct {
    name:    Edit_Buf,
    note:    Edit_Buf,
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
# Build time: codegen emits src/gen_entity.odin (the struct, defaults and EN/ZH labels); nothing reads
# this file at run time. Edited by the in-engine schema editor, which rewrites it whole, so explain things
# in "note" lines, not comments. Section order = struct/member order.
#
# Grammar — INI with TOML-style dotted sections. Every declaration is a [qualified.name]
# section followed by "key = value" attribute lines:
#
#   [field.<id>]                 type / en / zh / default / tags / section / builtin / note
#   [enum.<T>] / [flags.<T>]     a type (note);  [enum.<T>.<member>]   -> en / zh / note
#   [struct.<T>]                 a type (note);  [struct.<T>.<member>] -> type / en / zh / default / note
#
# Types: scalars (bool, i32, u32, f32, string, vec2, vec3, vec4, quat), owned inline text
# (sbuf64 / sbuf128 / sbuf256), the builtin-only Entity_Handle, and qualified refs to authored
# types: enum.<T> / flags.<T> /
# struct.<T>. A dot means the same thing in a header and in a type = reference.
#
# section = a member of enum.EntitySection: the inspector section the field is drawn under
# (sections in the enum's member order; fields without one go first, above them).
# tags = how the inspector treats the field: hidden / readonly / noserialize / identity, and widget:<kind>
# (model, texture, sound for string; icon for sbuf*; color, linear_color for vec3). Set in the schema editor.
# note = what it's for, one line; codegen writes it as a comment beside the generated declaration.
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

    r := Ini_Reader{text = string(data)}
    for line in ini_next(&r) {
        if line.header {
            parts := strings.split(line.section, ".", context.temp_allocator)
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

        key, val := line.key, line.value
        switch target {
        case .None:
        case .Field:
            f := &schema_doc.fields[len(schema_doc.fields) - 1]
            switch key {
            case "type":    edit_buf_set(&f.type, val)
            case "en":      edit_buf_set(&f.en, val)
            case "zh":      edit_buf_set(&f.zh, val)
            case "default": edit_buf_set(&f.default, val)
            case "tags":    _doc_parse_tags(f, val)
            case "section": edit_buf_set(&f.section, val)
            case "note":    edit_buf_set(&f.note, val)
            case "builtin": f.builtin = val == "true"
            }
        case .Type:
            t := &schema_doc.types[len(schema_doc.types) - 1]
            switch key {
            case "builtin": t.builtin = val == "true"
            case "note":    edit_buf_set(&t.note, val)
            }
        case .Member:
            t := &schema_doc.types[len(schema_doc.types) - 1]
            m := &t.members[len(t.members) - 1]
            switch key {
            case "type":    edit_buf_set(&m.type, val)
            case "en":      edit_buf_set(&m.en, val)
            case "zh":      edit_buf_set(&m.zh, val)
            case "default": edit_buf_set(&m.default, val)
            case "note":    edit_buf_set(&m.note, val)
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
        _doc_write_kv_opt(&b, "tags", _doc_tags_string(&f))
        _doc_write_kv_opt(&b, "section", edit_buf_str(&f.section))
        _doc_write_kv_opt(&b, "en", edit_buf_str(&f.en))
        _doc_write_kv_opt(&b, "zh", edit_buf_str(&f.zh))
        _doc_write_kv_opt(&b, "default", edit_buf_str(&f.default))
        _doc_write_kv_opt(&b, "note", edit_buf_str(&f.note))
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
            _doc_write_kv_opt(&b, "note", edit_buf_str(&t.note))
            for &m in t.members {
                fmt.sbprintfln(&b, "\n[%s.%s.%s]", kind, name, edit_buf_str(&m.id))
                if t.kind == .Struct do _doc_write_kv(&b, "type", edit_buf_str(&m.type))
                _doc_write_kv_opt(&b, "en", edit_buf_str(&m.en))
                _doc_write_kv_opt(&b, "zh", edit_buf_str(&m.zh))
                if t.kind == .Struct do _doc_write_kv_opt(&b, "default", edit_buf_str(&m.default))
                _doc_write_kv_opt(&b, "note", edit_buf_str(&m.note))
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
        if sec := edit_buf_str(&f.section); sec != "" && !schema_doc_is_section(sec) {
            return false, strings.concatenate({"field '", id, "' has unknown section (not in enum ", SCHEMA_SECTION_ENUM, "): ", sec}, context.temp_allocator)
        }
        if w := edit_buf_str(&f.widget); w != "" && !schema_widget_fits(w, t) {
            return false, strings.concatenate({"field '", id, "' has widget '", w, "', which doesn't fit type ", t}, context.temp_allocator)
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

/* ------------------------------ tags ------------------------------ */

// A field's tags, as the schema editor offers them. The INI keeps them as one `tags = a, b, widget:x`
// line (codegen copies it into the struct tag verbatim); the editor shows a toggle per flag tag and a
// dropdown of the widgets that fit the field's type. A tag the inspector starts reading goes here.
SCHEMA_FLAG_TAGS :: [?]struct{ tag: string, label: Loc_ID }{
    {"hidden",      .Schema_Tag_Hidden},        // not drawn in the inspector
    {"readonly",    .Schema_Tag_Readonly},      // drawn disabled
    {"noserialize", .Schema_Tag_Noserialize},   // never saved, copied or set from text (Lua still writes it)
    {"identity",    .Schema_Tag_Identity},      // never copied to the rest of the selection by multi-edit
}

// `widget:<name>`: how the inspector edits a field of `type` (ui_param_struct).
@(rodata) schema_widgets := [?]struct{ name: string, types: []string, label: Loc_ID }{
    {"model",        {"string"},                       .Schema_Widget_Model},
    {"texture",      {"string"},                       .Schema_Widget_Texture},
    {"sound",        {"string"},                       .Schema_Widget_Sound},
    {"icon",         {"sbuf64", "sbuf128", "sbuf256"}, .Schema_Widget_Icon},
    {"color",        {"vec3"},                         .Schema_Widget_Color},
    {"linear_color", {"vec3"},                         .Schema_Widget_Linear_Color},
}

schema_widget_fits :: proc(widget, type: string) -> bool {
    for w in schema_widgets do if w.name == widget {
        for t in w.types do if t == type do return true
    }
    return false
}

@(private = "file")
_doc_parse_tags :: proc(f: ^Doc_Field, tags: string) {
    s := tags
    next: for part in strings.split_iterator(&s, ",") {
        tag := strings.trim_space(part)
        if tag == "" do continue
        if strings.has_prefix(tag, "widget:") {
            edit_buf_set(&f.widget, tag[len("widget:"):])
            continue
        }
        for ft, i in SCHEMA_FLAG_TAGS do if ft.tag == tag {
            f.flags[i] = true
            continue next
        }
        log.warnf("schema_doc: field '%v' has unknown tag '%v'; it will be dropped on save", edit_buf_str(&f.id), tag)
    }
}

// The `tags =` value: the flag tags in SCHEMA_FLAG_TAGS order, then the widget.
@(private = "file")
_doc_tags_string :: proc(f: ^Doc_Field) -> string {
    b := strings.builder_make(context.temp_allocator)
    for ft, i in SCHEMA_FLAG_TAGS do if f.flags[i] {
        if strings.builder_len(b) > 0 do strings.write_string(&b, ", ")
        strings.write_string(&b, ft.tag)
    }
    if w := edit_buf_str(&f.widget); w != "" {
        if strings.builder_len(b) > 0 do strings.write_string(&b, ", ")
        fmt.sbprintf(&b, "widget:%s", w)
    }
    return strings.to_string(b)
}

/* ------------------------------ helpers ------------------------------ */

// The enum whose members are the inspector's sections (their order is the inspector's order).
SCHEMA_SECTION_ENUM :: "EntitySection"

// The section enum, or nil if the schema has none.
schema_doc_sections :: proc() -> ^Doc_Type {
    for &t in schema_doc.types do if t.kind == .Enum && edit_buf_str(&t.name) == SCHEMA_SECTION_ENUM do return &t
    return nil
}

schema_doc_is_section :: proc(member: string) -> bool {
    t := schema_doc_sections()
    if t == nil do return false
    for &m in t.members do if edit_buf_str(&m.id) == member do return true
    return false
}

// Points the fields in section `old` at `new` ("" = none: the top, above the sections), after a group was
// renamed or removed. Skipped while another group still has `old`, so a rename passing through an existing
// id doesn't take that group's fields along.
schema_doc_rename_section :: proc(old, new: string) {
    if old == "" || schema_doc_is_section(old) do return
    for &f in schema_doc.fields do if edit_buf_str(&f.section) == old do edit_buf_set(&f.section, new)
}

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
