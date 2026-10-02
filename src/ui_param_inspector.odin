package blimp

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:math/linalg"
import "core:reflect"
import "core:slice"
import im "lib:odin-imgui"

// Reflection-driven property editor. Renders imgui widgets for a struct's fields automatically,
// so new fields show up in the inspector without hand-wiring UI. Laid out as a form (like the
// schema editor): a left-aligned label column, then the input filling the rest of the row, with
// nested structs as indented collapsible sub-sections. Per-field backtick tags control it:
// `hidden` skips a field, `readonly` disables it.

Param_UI_Options :: struct {
    readonly:     bool,
    headerless:   bool,
    label_w:      f32,   // x (px) where inputs start on each row; set per-struct so labels align
    speed:        f32,
    min:          f32,
    max:          f32,
    format:       string,
    slider_flags: im.SliderFlags,
    combo_flags:  im.ComboFlags,
    path:         string,   // serialized key of the item being drawn ("model", "transform.position"); "" = top struct
}

DEFAULT_PARAM_UI_OPTIONS :: Param_UI_Options {
    speed  = 0.01,
    format = "%.3f",
}

// A form-row prefix: left-aligned label, then the next item starts at the shared column, full width.
@(private="file")
ui_param_label :: proc(label: string, options: Param_UI_Options) {
    im.AlignTextToFramePadding()
    im.TextUnformatted(fmt.ctprintf("%s", label))
    im.SameLine(options.label_w)
    im.SetNextItemWidth(-1)
}

ui_param_bool :: proc(name: string, value: ^bool, options := DEFAULT_PARAM_UI_OPTIONS) {
    ui_param_label(name, options)
    im.BeginDisabled(options.readonly)
    im.Checkbox(fmt.ctprintf("##%s", name), value)
    im.EndDisabled()
}

// Text has two types, chosen by who owns it:
//   sbuf64 — text the struct owns (names, tags, labels): edited in place (ui_param_sbuf).
//   string — a reference to text owned elsewhere (e.g. an asset key in the asset arena): never
//            edited as free text. A `widget:<kind>` tag picks how it's chosen; without one it's
//            shown read-only, dimmed, as below.
ui_param_string :: proc(name: string, value: string, options := DEFAULT_PARAM_UI_OPTIONS) {
    ui_param_label(name, options)
    im.TextDisabled("%s", fmt.ctprintf("%s", value))
}

Asset_Kind :: enum { Model, Texture }

// `widget:model` / `widget:texture`: a dropdown over the keys of every loaded model / texture
// (filled at startup when the glTFs load). The field ends up referencing the asset system's own
// interned key — the asset arena owns the string — so picking allocates nothing.
//
// A paste button sits beside it: takes this field's value from the clipboard — the matching
// `key = value` line of a copied entity (copy a car in a kit, paste just its model onto another
// entity), or a bare key on its own — and applies it only if it names a loaded asset. Greyed out
// when the clipboard doesn't resolve to one.
ui_param_asset_picker :: proc(name: string, value: ^string, kind: Asset_Kind, options := DEFAULT_PARAM_UI_OPTIONS) {
    ui_param_label(name, options)
    im.BeginDisabled(options.readonly)

    paste_label := fmt.ctprintf("%s", ICON_PASTE)   // icon button; the name is its tooltip
    style := im.GetStyle()
    paste_w := im.CalcTextSize(paste_label).x + style.FramePadding.x * 2
    im.SetNextItemWidth(-(paste_w + style.ItemSpacing.x))   // leave room for the button on this row

    if im.BeginCombo(fmt.ctprintf("##%s", name), fmt.ctprintf("%s", value^), {.HeightLarge}) {
        keys := make([dynamic]string, context.temp_allocator)   // gathered only while the dropdown is open
        switch kind {
        case .Model:   for key in asset_system.models    do append(&keys, key)
        case .Texture: for key in asset_system.image_ids do append(&keys, key)
        }
        slice.sort(keys[:])
        for key in keys {
            if im.Selectable(fmt.ctprintf("%s", key), key == value^) do value^ = key
        }
        im.EndCombo()
    }

    im.SameLine()
    pasted, has_paste := asset_key_from_clipboard(options.path, kind)
    im.BeginDisabled(!has_paste)
    if im.SmallButton(fmt.ctprintf("%s##paste_%s", paste_label, name)) do value^ = pasted
    im.SetItemTooltip("%s", tr(.Btn_Paste))
    im.EndDisabled()

    im.EndDisabled()
}

// The clipboard's value for field `key`, as the asset system's own interned key, if it names a
// loaded model / texture.
@(private="file")
asset_key_from_clipboard :: proc(key: string, kind: Asset_Kind) -> (string, bool) {
    text, ok := text_field_value(string(im.GetClipboardText()), key)
    if !ok do return "", false
    switch kind {
    case .Model:
        if m, found := asset_system.models[text]; found do return m.key, true
    case .Texture:
        for k in asset_system.image_ids do if k == text do return k, true
    }
    return "", false
}

// Editable inline string (sbuf64/128/256). Each size has a fixed capacity, so a stack buffer one
// byte larger than the biggest (for the NUL ImGui needs) round-trips it with no allocation; ImGui
// is told the field's real capacity so it can't accept more than fits. Edits write straight back.
ui_param_sbuf :: proc(name: string, value: any, options := DEFAULT_PARAM_UI_OPTIONS) {
    text, ok := sbuf_any_str(value)
    if !ok do return
    ui_param_label(name, options)
    buf: [cap(sbuf256{}) + 1]u8
    copy(buf[:], text)
    im.BeginDisabled(options.readonly)
    if im.InputText(fmt.ctprintf("##%s", name), cstring(&buf[0]), uint(sbuf_any_cap(value) + 1)) {
        sbuf_any_set(value, string(cstring(&buf[0])))
    }
    im.EndDisabled()
}

ui_param_int :: proc(name: string, value: rawptr, size: int, signed: bool, options := DEFAULT_PARAM_UI_OPTIONS) {
    dt: im.DataType
    switch size {
        case 1: dt = signed ? .S8  : .U8
        case 2: dt = signed ? .S16 : .U16
        case 8: dt = signed ? .S64 : .U64
        case:   dt = signed ? .S32 : .U32
    }
    ui_param_label(name, options)
    im.BeginDisabled(options.readonly)
    im.InputScalar(fmt.ctprintf("##%s", name), dt, value)
    im.EndDisabled()
}

ui_param_f32 :: proc(name: string, value: ^f32, options := DEFAULT_PARAM_UI_OPTIONS) {
    cformat := strings.clone_to_cstring(options.format, context.temp_allocator)
    ui_param_label(name, options)
    im.BeginDisabled(options.readonly)
    im.DragFloat(fmt.ctprintf("##%s", name), value, options.speed, options.min, options.max, cformat, options.slider_flags)
    im.EndDisabled()
}

ui_param_vec2 :: proc(name: string, value: ^vec2, options := DEFAULT_PARAM_UI_OPTIONS) {
    cformat := strings.clone_to_cstring(options.format, context.temp_allocator)
    ui_param_label(name, options)
    im.BeginDisabled(options.readonly)
    im.DragFloat2(fmt.ctprintf("##%s", name), value, options.speed, options.min, options.max, cformat, options.slider_flags)
    im.EndDisabled()
}

ui_param_vec3 :: proc(name: string, value: ^vec3, options := DEFAULT_PARAM_UI_OPTIONS) {
    cformat := strings.clone_to_cstring(options.format, context.temp_allocator)
    ui_param_label(name, options)
    im.BeginDisabled(options.readonly)
    im.DragFloat3(fmt.ctprintf("##%s", name), value, options.speed, options.min, options.max, cformat, options.slider_flags)
    im.EndDisabled()
}

ui_param_vec4 :: proc(name: string, value: ^vec4, options := DEFAULT_PARAM_UI_OPTIONS) {
    cformat := strings.clone_to_cstring(options.format, context.temp_allocator)
    ui_param_label(name, options)
    im.BeginDisabled(options.readonly)
    im.DragFloat4(fmt.ctprintf("##%s", name), value, options.speed, options.min, options.max, cformat, options.slider_flags)
    im.EndDisabled()
}

ui_param_quat :: proc(name: string, value: ^quat, options := DEFAULT_PARAM_UI_OPTIONS) {
    cformat := strings.clone_to_cstring(options.format, context.temp_allocator)
    ui_param_label(name, options)
    im.BeginDisabled(options.readonly)
    im.DragFloat4(fmt.ctprintf("##%s", name), cast(^vec4)value, options.speed, options.min, options.max, cformat, options.slider_flags)
    value^ = linalg.quaternion_normalize(value^)
    im.EndDisabled()
}

ui_param_enum :: proc(name: string, type: typeid, value: ^u64, options := DEFAULT_PARAM_UI_OPTIONS) {
    enum_type, _ := type_info_of(type).variant.(runtime.Type_Info_Enum)
    type_name := param_type_name(type_info_of(type))
    selected_enum_name, _ := reflect.enum_name_from_value_any(any{value, type})
    ui_param_label(name, options)
    im.BeginDisabled(options.readonly)
    // Compare against raw member names; display the localized label.
    if im.BeginCombo(fmt.ctprintf("##%s", name), fmt.ctprintf("%s", param_member_label(type_name, selected_enum_name)), options.combo_flags) {
        for enum_name in enum_type.names {
            is_selected := selected_enum_name == enum_name
            if im.Selectable(fmt.ctprintf("%s##%s", param_member_label(type_name, enum_name), enum_name), is_selected) {
                enum_value, _ := reflect.enum_from_name_any(type, enum_name)
                value^ = u64(enum_value)
            }
        }
        im.EndCombo()
    }
    im.EndDisabled()
}

ui_param_bitset :: proc(name: string, type: typeid, value: ^u64, options := DEFAULT_PARAM_UI_OPTIONS) {
    typeinfo, _ := type_info_of(type).variant.(runtime.Type_Info_Bit_Set)
    type_name := param_type_name(typeinfo.elem)
    enum_names := reflect.enum_field_names(typeinfo.elem.id)
    // Label, then the flag checkboxes flow across the row starting at the input column.
    ui_param_label(name, options)
    im.BeginDisabled(options.readonly)
    for enum_name, j in enum_names {
        checked := value^ & (1 << u32(j)) > 0
        if im.Checkbox(fmt.ctprintf("%s##%s", param_member_label(type_name, enum_name), enum_name), &checked) {
            value^ ~= 1 << u32(j)
        }
        if j < len(enum_names) - 1 do im.SameLine()
    }
    im.EndDisabled()
}

// First tag of the form `<key><value>` (e.g. "loc:Field_Name"), value returned.
@(private="file")
param_tag_value :: proc(tags: []string, key: string) -> (string, bool) {
    for t in tags {
        if strings.has_prefix(t, key) {
            return t[len(key):], true
        }
    }
    return "", false
}

// Splits a field's backtick tag string into trimmed parts (e.g. "hidden, readonly").
@(private="file")
param_field_tags :: proc(tag: reflect.Struct_Tag) -> []string {
    s := strings.clone(string(tag), context.temp_allocator)
    if len(s) == 0 do return nil
    parts := strings.split(s, ",", context.temp_allocator)
    for &t in parts do t = strings.trim_space(t)
    return parts
}

// Resolves a field's display label. For a nested struct member (owner_type set) the schema is
// keyed "<StructType>.<member>"; for a top-level Entity field (owner_type == "") it's keyed by
// bare field name. Then a `loc:<Loc_ID>` tag (hand-authored structs), else the raw field name.
@(private="file")
param_field_label :: proc(owner_type: string, field_name: string, tags: []string) -> string {
    if owner_type != "" {
        if s, ok := entity_struct_member_label(owner_type, field_name); ok do return s
    } else {
        if s, ok := entity_field_label(field_name); ok do return s
    }
    if key, ok := param_tag_value(tags, "loc:"); ok {
        if id, found := reflect.enum_from_name(Loc_ID, key); found {
            return string(tr(id))
        }
    }
    return field_name
}

// Name of a named type (e.g. the enum behind a bit_set), or "" if unnamed.
@(private="file")
param_type_name :: proc(ti: ^runtime.Type_Info) -> string {
    #partial switch v in ti.variant {
    case runtime.Type_Info_Named: return v.name
    }
    return ""
}

// Localized label for one enum/bit-set member via the entity schema, keyed on the enum's
// type name; falls back to the raw member id.
@(private="file")
param_member_label :: proc(enum_type: string, member: string) -> string {
    if s, ok := entity_flag_item_label(enum_type, member); ok {
        return s
    }
    return member
}

ui_param_struct :: proc(name: string, type: typeid, value: any, options := DEFAULT_PARAM_UI_OPTIONS, owner_type := "") {
    // A named sub-struct renders as an indented collapsible section; the top-level call is headerless.
    if !options.headerless {
        if !im.CollapsingHeader(fmt.ctprintf("%s", name)) do return
        im.Indent()
    }

    attr_count := reflect.struct_field_count(type)
    struct_tags := reflect.struct_field_tags(type)

    // Shared input column for this struct: widest visible label + a gap, so rows line up
    // regardless of language (labels differ in width between EN and the larger ZH font).
    col: f32 = 0
    for i in 0 ..< attr_count {
        tags := param_field_tags(struct_tags[i])
        if contains(tags, "hidden") do continue
        field := reflect.struct_field_at(type, i)
        w := im.CalcTextSize(fmt.ctprintf("%s", param_field_label(owner_type, field.name, tags))).x
        if w > col do col = w
    }
    col += 16 * app.dispaly_scale

    for i in 0 ..< attr_count {
        tags := param_field_tags(struct_tags[i])
        if contains(tags, "hidden") do continue

        field := reflect.struct_field_at(type, i)
        field_type := field.type
        field_value := reflect.struct_field_value(value, field)

        field_options := DEFAULT_PARAM_UI_OPTIONS
        field_options.readonly = options.readonly || contains(tags, "readonly")
        field_options.label_w  = col
        field_options.path     = options.path == "" ? field.name : fmt.tprintf("%s.%s", options.path, field.name)   // same dotted key serialize writes

        // Field label (schema-driven for Entity; loc tag fallback otherwise). Enum/bit-set
        // member names are localized inside the widgets via the entity schema.
        label := param_field_label(owner_type, field.name, tags)

        im.PushIDInt(i32(i))   // stable per-field id so widgets can use bare ##labels
        #partial switch typeinfo in field_type.variant {
            case runtime.Type_Info_Boolean:
                ui_param_bool(label, &field_value.(bool), field_options)
            case runtime.Type_Info_String:
                widget, _ := param_tag_value(tags, "widget:")
                switch widget {
                case "model":   ui_param_asset_picker(label, &field_value.(string), .Model,   field_options)
                case "texture": ui_param_asset_picker(label, &field_value.(string), .Texture, field_options)
                case:           ui_param_string(label, field_value.(string), field_options)   // no/unknown widget: read-only
                }
            case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
                ui_param_sbuf(label, field_value, field_options)   // sbuf64/128/256; other fixed arrays are skipped
            case runtime.Type_Info_Integer:
                ui_param_int(label, field_value.data, field_type.size, typeinfo.signed, field_options)
            case runtime.Type_Info_Float:
                ui_param_f32(label, &field_value.(f32), field_options)
            case runtime.Type_Info_Quaternion:
                ui_param_quat(label, &field_value.(quat), field_options)
            case runtime.Type_Info_Bit_Set:
                ui_param_bitset(label, field_type.id, cast(^u64)field_value.data, field_options)
            case runtime.Type_Info_Named:
                base := typeinfo.base
                #partial switch _ in base.variant {
                    case runtime.Type_Info_Enum:
                        ui_param_enum(label, base.id, cast(^u64)field_value.data, field_options)
                    case runtime.Type_Info_Struct:
                        ui_param_struct(label, base.id, field_value, field_options, typeinfo.name)
                }
            case runtime.Type_Info_Array:
                #partial switch _ in typeinfo.elem.variant {
                    case runtime.Type_Info_Float:
                        switch typeinfo.count {
                            case 2: ui_param_vec2(label, &field_value.(vec2), field_options)
                            case 3:
                                if widget, _ := param_tag_value(tags, "widget:"); widget == "color" do ui_param_color(label, &field_value.([3]f32), field_options)
                                else do ui_param_vec3(label, &field_value.(vec3), field_options)
                            case 4: ui_param_vec4(label, &field_value.(vec4), field_options)
                        }
                }
        }
        im.PopID()
        im.Dummy({0, 3 * app.dispaly_scale})
    }

    if !options.headerless do im.Unindent()
}

// An RGB colour (a [3]f32 tagged `widget:color`): swatch + picker.
ui_param_color :: proc(name: string, value: ^[3]f32, options := DEFAULT_PARAM_UI_OPTIONS) {
    ui_param_label(name, options)
    im.BeginDisabled(options.readonly)
    im.ColorEdit3(fmt.ctprintf("##%s", name), value)
    im.EndDisabled()
}
