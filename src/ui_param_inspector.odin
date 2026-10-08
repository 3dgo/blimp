package blimp

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:math/linalg"
import "core:mem"
import "core:reflect"
import "core:slice"
import im "lib:odin-imgui"

// Reflection-driven property editor. Renders imgui widgets for a struct's fields automatically,
// so new fields show up in the inspector without hand-wiring UI. Laid out as a form (like the
// schema editor): a left-aligned label column, then the input filling the rest of the row, with
// nested structs as indented collapsible sub-sections. Per-field backtick tags control it:
// `hidden` skips a field, `readonly` disables it, `section:<Member>` draws it under that EntitySection
// header (fields without one come first, then the sections in the enum's order).
//
// The entity inspector also passes the defaults (a field that differs from its default has a bold label,
// and right-clicking a label resets it), the other selected entities (a field where they differ is drawn
// mixed), and the search text.
//
// An Entity's conditional fields (the schema's `when` entries, Entity_Field_Use) get a dot before the label
// while one of their conditions holds; fields without any get none. Hovering the label or dot shows the field's tooltip; hovering the dot also
// lights the dots of the fields that go with it: what turns it on (light_type) and what else that turns on.

Param_UI_Options :: struct {
    readonly:     bool,
    headerless:   bool,
    label_w:      f32,   // x (px) where inputs start on each row; set per-struct so labels align
    speed:        f32,
    min:          f32,
    max:          f32,
    format:       string,
    filter:       string,   // search text (search_matches: any case, pinyin): only fields whose id or label (any language) contains it; top struct only
    defaults:     rawptr,   // the struct's default value, or nil
    others:       []rawptr, // other values edited along with this one (the rest of a multi-selection)
    // Per field, set by ui_param_struct for the widget's label:
    overridden:   bool,   // differs from its default (bold label)
    mixed:        bool,
    resettable:   bool,
}

PARAM_MIXED_FORMAT :: "—"   // a number that differs across the selection shows a dash

// The dot under the mouse: which inspector (its ID stack), which field, and the frame it was last seen.
// The next draw lights the dots from it, a frame late, which no one sees.
@(private="file")
param_dot_hover: struct { window: im.ID, field: string, frame: i32 }

// The clicked dot: its group stays lit, through scrolling, until a lit dot is clicked again.
@(private="file")
param_dot_lock: struct { window: im.ID, field: string }

// An entity inspector's dots for one draw.
@(private="file")
Param_Dots :: struct {
    e:       ^Entity,
    window:  im.ID,
    source:  string,             // the locked dot's field, else the hovered one's; "" = none
    locked:  bool,
    drivers: [dynamic]string,    // the fields that turn the source on (named by its uses that hold)
}

DEFAULT_PARAM_UI_OPTIONS :: Param_UI_Options {
    speed  = 0.01,
    format = "%.3f",
}

// The last form row: where it began (after its gap), and its gutter's mouse state. The entity inspector
// draws that field's dot there and takes clicks on it.
@(private="file") param_row_pos: im.Vec2
@(private="file") param_row_gutter_hovered, param_row_gutter_clicked: bool

// Starts a form row: the gap above it, so every form's rows are spaced alike.
@(private="file")
param_row_begin :: proc() {
    im.Dummy({0, UI_ROW_GAP * app.display_scale})
    param_row_pos = im.GetCursorScreenPos()
    param_row_gutter_hovered, param_row_gutter_clicked = false, false
}

// A form-row prefix: the gutter, a left-aligned label, then the next item starts at the shared column, full
// width. Every panel's rows start with it. A field that's been set (differs from its default) has a bold
// label, so it stands out; mixed (differs across the selection) is amber. Right-click opens the field's menu
// (ui_param_struct draws it).
ui_param_label :: proc(label: string, options: Param_UI_Options) {
    param_row_begin()
    // The gutter is a button, so a click there (on a dot) is the row's, not a drag of the window.
    param_row_gutter_clicked = im.InvisibleButton(fmt.ctprintf("##gutter_%s", label), {ui_gutter(), im.GetFrameHeight()})
    param_row_gutter_hovered = im.IsItemHovered()
    im.SameLine(0, 0)
    im.AlignTextToFramePadding()
    text := fmt.ctprintf("%s", label)
    if options.overridden do im.PushFontFloat(ui.font_bold, 0)
    if options.mixed do im.TextColored(UI_COLOR_WARNING, "%s", text)
    else do im.TextUnformatted(text)
    if options.overridden do im.PopFont()
    if options.mixed do im.SetItemTooltip("%s", tr(.Inspector_Mixed))
    if options.resettable && im.IsItemHovered() && im.IsMouseReleased(.Right) do im.OpenPopup("param_menu")
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

Asset_Kind :: enum { Model, Texture, Sound }

// `widget:model` / `widget:texture` / `widget:sound`: a dropdown over the keys of every loaded model /
// texture / sound clip, and none. The field ends up referencing the interned key (asset_intern), so it
// survives an asset reload. A key nothing loaded under (a file since moved or deleted) still shows,
// in red.
//
// A paste button sits beside it: takes this field's value from the clipboard — the matching
// `key = value` line of a copied entity (copy an entity in a kit, paste just its model onto another
// entity), or a bare key on its own — and applies it only if it names a loaded asset. Greyed out
// when the clipboard doesn't resolve to one.
ui_param_asset_picker :: proc(name: string, value: ^string, kind: Asset_Kind, options := DEFAULT_PARAM_UI_OPTIONS) {
    ui_param_label(name, options)
    im.BeginDisabled(options.readonly)

    missing := false
    if value^ != "" {
        switch kind {
        case .Model:   missing = value^ not_in asset_system.models
        case .Texture: missing = value^ not_in asset_system.image_ids
        case .Sound:   missing = sound_system.ok && value^ not_in sound_system.clip_ids   // no audio device: nothing loaded, nothing broken
        }
    }
    if missing do im.PushStyleColorImVec4(.Text, UI_COLOR_ERROR)
    open := im.BeginCombo(fmt.ctprintf("##%s", name), fmt.ctprintf("%s", value^), {.HeightLarge})
    if missing do im.PopStyleColor()   // before the list, so only the preview is red
    if open {
        keys := make([dynamic]string, context.temp_allocator)   // gathered only while the dropdown is open
        switch kind {
        case .Model:   for key in asset_system.models    do append(&keys, key)
        case .Texture: for key in asset_system.image_ids do append(&keys, key)
        case .Sound:   append(&keys, ..sound_clip_keys(context.temp_allocator))
        }
        slice.sort(keys[:])
        if im.Selectable(tr(.Asset_None), value^ == "") do value^ = ""
        for key in keys {
            if im.Selectable(fmt.ctprintf("%s", key), key == value^) do value^ = asset_intern(key)
        }
        im.EndCombo()
    }

    im.EndDisabled()
}

// Editable inline string (sbuf64/128/256). Each size has a fixed capacity, so a stack buffer one
// byte larger than the biggest (for the NUL ImGui needs) round-trips it with no allocation; ImGui
// is told the field's real capacity so it can't accept more than fits. Edits write straight back.
// `shown` is an extra bit of label after the name (an icon field's glyph); it isn't part of the ID, so
// it can change while the field is being typed in.
ui_param_sbuf :: proc(name: string, value: any, options := DEFAULT_PARAM_UI_OPTIONS, shown := "") {
    text, ok := sbuf_any_str(value)
    if !ok do return
    ui_param_label(shown == "" ? name : fmt.tprintf("%s  %s", name, shown), options)
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
    im.DragFloat(fmt.ctprintf("##%s", name), value, options.speed, options.min, options.max, cformat)
    im.EndDisabled()
}

ui_param_vec2 :: proc(name: string, value: ^vec2, options := DEFAULT_PARAM_UI_OPTIONS) {
    cformat := strings.clone_to_cstring(options.format, context.temp_allocator)
    ui_param_label(name, options)
    im.BeginDisabled(options.readonly)
    im.DragFloat2(fmt.ctprintf("##%s", name), value, options.speed, options.min, options.max, cformat)
    im.EndDisabled()
}

ui_param_vec3 :: proc(name: string, value: ^vec3, options := DEFAULT_PARAM_UI_OPTIONS) {
    cformat := strings.clone_to_cstring(options.format, context.temp_allocator)
    ui_param_label(name, options)
    im.BeginDisabled(options.readonly)
    im.DragFloat3(fmt.ctprintf("##%s", name), value, options.speed, options.min, options.max, cformat)
    im.EndDisabled()
}

ui_param_vec4 :: proc(name: string, value: ^vec4, options := DEFAULT_PARAM_UI_OPTIONS) {
    cformat := strings.clone_to_cstring(options.format, context.temp_allocator)
    ui_param_label(name, options)
    im.BeginDisabled(options.readonly)
    im.DragFloat4(fmt.ctprintf("##%s", name), value, options.speed, options.min, options.max, cformat)
    im.EndDisabled()
}

ui_param_quat :: proc(name: string, value: ^quat, options := DEFAULT_PARAM_UI_OPTIONS) {
    cformat := strings.clone_to_cstring(options.format, context.temp_allocator)
    ui_param_label(name, options)
    im.BeginDisabled(options.readonly)
    // Normalized only when dragged: a write every frame would count as an edit (an undo step, and under
    // multi-edit the active rotation copied onto the whole selection) whenever rounding moved a bit.
    if im.DragFloat4(fmt.ctprintf("##%s", name), cast(^vec4)value, options.speed, options.min, options.max, cformat) {
        value^ = linalg.quaternion_normalize(value^)
    }
    im.EndDisabled()
}

ui_param_enum :: proc(name: string, type: typeid, value: ^u64, options := DEFAULT_PARAM_UI_OPTIONS) {
    enum_type, _ := runtime.type_info_base(type_info_of(type)).variant.(runtime.Type_Info_Enum)
    type_name := param_type_name(type_info_of(type))
    selected_enum_name, _ := reflect.enum_name_from_value_any(any{value, type})
    ui_param_label(name, options)
    im.BeginDisabled(options.readonly)
    // Compare against raw member names; display the localized label.
    // Each choice's tooltip (schema tip_en / tip_zh) on its item, and the current one's on the closed combo.
    open := im.BeginCombo(fmt.ctprintf("##%s", name), fmt.ctprintf("%s", param_member_label(type_name, selected_enum_name)))
    if !open do ui_item_tooltip(entity_member_tip(type_name, selected_enum_name))
    if open {
        for enum_name in enum_type.names {
            is_selected := selected_enum_name == enum_name
            if im.Selectable(fmt.ctprintf("%s##%s", param_member_label(type_name, enum_name), enum_name), is_selected) {
                enum_value, _ := reflect.enum_from_name_any(type, enum_name)
                value^ = u64(enum_value)
            }
            ui_item_tooltip(entity_member_tip(type_name, enum_name))
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
        ui_item_tooltip(entity_member_tip(type_name, enum_name))
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
    // A nested struct is a row like its siblings, not a section bar: its fold arrow in the gutter and its
    // name in the label column, opening into an indented panel that shows where it ends. The top-level call
    // is headerless.
    if !options.headerless {
        param_row_begin()
        if !im.TreeNodeEx(fmt.ctprintf("%s###struct", name), {.NoTreePushOnOpen, .FramePadding}) do return
        im.Indent()
        ui_card_begin()
    }

    attr_count := reflect.struct_field_count(type)
    struct_tags := reflect.struct_field_tags(type)

    // Shared input column for this struct: gutter + widest visible label + a gap, so rows line up
    // regardless of language (labels differ in width between EN and the larger ZH font). Measured in bold,
    // the wider of the two, since any label may turn bold.
    col: f32 = 0
    im.PushFontFloat(ui.font_bold, 0)
    for i in 0 ..< attr_count {
        tags := param_field_tags(struct_tags[i])
        if contains(tags, "hidden") do continue
        field := reflect.struct_field_at(type, i)
        w := im.CalcTextSize(fmt.ctprintf("%s", param_field_label(owner_type, field.name, tags))).x
        if w > col do col = w
    }
    im.PopFont()
    col = ui_label_column_at(col)

    dots: ^Param_Dots
    d: Param_Dots
    if type == Entity {
        d = {e = (^Entity)(value.data), window = im.GetID("param_dots")}
        d.drivers = make([dynamic]string, context.temp_allocator)
        if l := param_dot_lock; l.window == d.window && l.field != "" {
            d.source, d.locked = l.field, true
        } else if h := param_dot_hover; h.window == d.window && h.frame >= im.GetFrameCount() - 1 {
            d.source = h.field
        }
        for u in entity_field_uses(d.source) do if u.holds(d.e) do append(&d.drivers, ..u.fields)
        // A lock on a field this entity doesn't use (another one got selected) has no dot to click: drop it.
        if d.locked && len(d.drivers) == 0 {
            param_dot_lock = {}
            d.source, d.locked = "", false
        }
        dots = &d
    }

    // Fields without a section, then one header per section. While searching, sections are plain
    // separators (so nothing found stays folded away), and a section whose name matches shows all its fields.
    param_struct_fields(type, value, options, owner_type, "", false, col, dots)
    for section in reflect.enum_field_names(EntitySection) {
        label := param_member_label("EntitySection", section)
        whole := options.filter != "" && search_matches(label, options.filter)
        any_shown := false
        for i in 0 ..< attr_count {
            tags := param_field_tags(struct_tags[i])
            if s, _ := param_tag_value(tags, "section:"); s != section do continue
            if whole || param_field_shown(owner_type, reflect.struct_field_at(type, i), value, tags, options.filter) {
                any_shown = true
                break
            }
        }
        if !any_shown do continue
        if options.filter != "" {
            ui_heading(fmt.ctprintf("%s", label))
        } else if !im.CollapsingHeader(fmt.ctprintf("%s###section_%s", label, section), {.DefaultOpen}) {
            continue
        }
        param_struct_fields(type, value, options, owner_type, section, whole, col, dots)
    }

    if !options.headerless {
        ui_card_end()
        im.Unindent()
    }
}

// One section's fields (`section` "" = those without one). `whole`: the search matched the section itself.
@(private="file")
param_struct_fields :: proc(type: typeid, value: any, options: Param_UI_Options, owner_type, section: string, whole: bool, col: f32, dots: ^Param_Dots) {
    attr_count := reflect.struct_field_count(type)
    struct_tags := reflect.struct_field_tags(type)
    for i in 0 ..< attr_count {
        tags := param_field_tags(struct_tags[i])
        if s, _ := param_tag_value(tags, "section:"); s != section do continue
        field := reflect.struct_field_at(type, i)
        if contains(tags, "hidden") || !whole && !param_field_shown(owner_type, field, value, tags, options.filter) do continue

        field_type := field.type
        field_value := reflect.struct_field_value(value, field)

        field_options := DEFAULT_PARAM_UI_OPTIONS
        field_options.readonly = options.readonly || contains(tags, "readonly")
        field_options.label_w  = col

        // Against the defaults and the rest of the selection. A mixed number shows a dash instead of the
        // active entity's value; dragging it still starts from that value.
        def: rawptr
        if options.defaults != nil {
            def = rawptr(uintptr(options.defaults) + field.offset)
            field_options.overridden = !param_value_equal(field_type, field_value.data, def)
            field_options.resettable = !field_options.readonly
        }
        for o in options.others {
            if !param_value_equal(field_type, field_value.data, rawptr(uintptr(o) + field.offset)) {
                field_options.mixed = true
                break
            }
        }
        if field_options.mixed do field_options.format = PARAM_MIXED_FORMAT

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
                case "sound":   ui_param_asset_picker(label, &field_value.(string), .Sound,   field_options)
                case:           ui_param_string(label, field_value.(string), field_options)   // no/unknown widget: read-only
                }
            case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
                // sbuf64/128/256; other fixed arrays are skipped. `widget:icon` (a hex codepoint) shows its glyph.
                shown: string
                if widget, _ := param_tag_value(tags, "widget:"); widget == "icon" {
                    if hex, ok := sbuf_any_str(field_value); ok do shown, _ = icon_from_hex(hex)
                }
                ui_param_sbuf(label, field_value, field_options, shown)
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
                        ui_param_enum(label, field_type.id, cast(^u64)field_value.data, field_options)
                    case runtime.Type_Info_Struct:
                        // Its members compare against the matching parts of the defaults and the selection.
                        sub := field_options
                        sub.defaults = def
                        if len(options.others) > 0 {
                            others := make([]rawptr, len(options.others), context.temp_allocator)
                            for o, j in options.others do others[j] = rawptr(uintptr(o) + field.offset)
                            sub.others = others
                        }
                        ui_param_struct(label, base.id, field_value, sub, typeinfo.name)
                }
            case runtime.Type_Info_Array:
                #partial switch _ in typeinfo.elem.variant {
                    case runtime.Type_Info_Float:
                        switch typeinfo.count {
                            case 2: ui_param_vec2(label, &field_value.(vec2), field_options)
                            case 3:
                                switch widget, _ := param_tag_value(tags, "widget:"); widget {
                                case "color":        ui_param_color(label, &field_value.([3]f32), false, field_options)
                                case "linear_color": ui_param_color(label, &field_value.([3]f32), true, field_options)
                                case:                ui_param_vec3(label, &field_value.(vec3), field_options)
                                }
                            case 4: ui_param_vec4(label, &field_value.(vec4), field_options)
                        }
                }
        }
        // The label's right-click menu (opened in ui_param_label).
        if field_options.resettable && im.BeginPopup("param_menu") {
            if im.MenuItem(tr(.Inspector_Reset), nil, false, field_options.overridden) do mem.copy(field_value.data, def, field_type.size)
            im.EndPopup()
        }
        im.PopID()
        if dots != nil do param_dot(dots, field.name, param_row_pos, col)
    }
}

// A field's dot, drawn while one of its uses holds and lit while it goes with the hovered or locked dot. A
// field without uses (name, transform, flags) is plainly always used, so it gets none. Hovering the dot or
// the label shows the field's tooltip; hovering the dot also lights the others. Clicking a dot locks its
// group lit (the locked one gets a ring); clicking a lit dot unlocks, any other moves the lock there.
@(private="file")
param_dot :: proc(d: ^Param_Dots, field: string, row: im.Vec2, col: f32) {
    uses := entity_field_uses(field)
    used := false
    lit := field == d.source || slice.contains(d.drivers[:], field)
    for u in uses do if u.holds(d.e) {
        used = true
        if param_use_lit(d, u) do lit = true
    }
    // In the gutter, centred where a fold arrow would be.
    h := im.GetFrameHeight()
    if used {
        center := row + {im.GetStyle().FramePadding.x + im.GetFontSize() * 0.5, h * 0.5}
        r := param_draw_dot(center, lit ? UI_COLOR_ACCENT : UI_COLOR_MARK, lit)
        if d.locked && field == d.source {
            im.DrawList_AddCircle(im.GetWindowDrawList(), center, r + 3 * app.display_scale, im.GetColorU32ImVec4(UI_COLOR_ACCENT), 0, 1.5 * app.display_scale)
        }
    }
    if used && param_row_gutter_clicked {
        param_dot_lock = {} if d.locked && lit else {d.window, field}
    }
    if !im.IsWindowHovered() do return
    if used && param_row_gutter_hovered do param_dot_hover = {d.window, field, im.GetFrameCount()}
    if im.IsMouseHoveringRect(row, row + {col, h}) do param_field_tooltip(d, field)
}

// Whether a use is part of the lit group: it holds and turns on with the hovered or locked dot's field.
@(private="file")
param_use_lit :: proc(d: ^Param_Dots, u: Entity_Field_Use) -> bool {
    if !u.holds(d.e) do return false
    for f in u.fields do if slice.contains(d.drivers[:], f) do return true
    return false
}

// The inspector's dot at `center`, larger when lit. Returns its radius.
@(private="file")
param_draw_dot :: proc(center: im.Vec2, color: im.Vec4, lit: bool) -> f32 {
    r := im.GetFontSize() * (lit ? 0.24 : 0.16)
    im.DrawList_AddCircleFilled(im.GetWindowDrawList(), center, r, im.GetColorU32ImVec4(color))
    return r
}

// A field's tip, then each of its uses as a list item: a dot, the condition, and under it what the field does
// then. A use in the lit group (hovered or locked dot) is blue, one that holds is white, the rest grey.
@(private="file")
param_field_tooltip :: proc(d: ^Param_Dots, field: string) {
    tip := entity_field_tip(field)
    uses := entity_field_uses(field)
    if tip == "" && len(uses) == 0 do return
    if !im.BeginTooltip() do return
    im.PushTextWrapPos(im.GetFontSize() * UI_TOOLTIP_WRAP)
    if tip != "" do im.TextUnformatted(fmt.ctprintf("%s", tip))
    dim  := im.GetStyleColorVec4(.TextDisabled)^
    text_color := im.GetStyleColorVec4(.Text)^
    for u in uses {
        holds, lit := u.holds(d.e), param_use_lit(d, u)
        color := lit ? UI_COLOR_ACCENT : holds ? text_color : dim
        if tip != "" || len(uses) > 1 do im.Spacing()
        bullet := im.GetFontSize()
        param_draw_dot(im.GetCursorScreenPos() + {bullet * 0.5, im.GetTextLineHeight() * 0.5}, color, lit)
        im.Indent(bullet)
        im.TextColored(color, "%s", fmt.ctprintf("%s", param_cond_label(u.cond)))
        if !holds do im.PushStyleColorImVec4(.Text, dim)
        text := u.text[loc_lang]
        if text == "" do text = u.text[.EN]
        im.TextUnformatted(fmt.ctprintf("%s", text))
        if !holds do im.PopStyleColor()
        im.Unindent(bullet)
    }
    im.PopTextWrapPos()
    im.EndTooltip()
}

// A `when` condition in the UI language, e.g. "Light = Spot / Cylinder"; terms joined by " + ".
@(private="file")
param_cond_label :: proc(cond: string) -> string {
    b := strings.builder_make(context.temp_allocator)
    c := cond
    for term in strings.split_iterator(&c, "&") {
        name, _, members := strings.partition(strings.trim_space(term), "=")
        name, members = strings.trim_space(name), strings.trim_space(members)
        if strings.builder_len(b) > 0 do strings.write_string(&b, " + ")
        strings.write_string(&b, param_field_label("", name, nil))
        if members == "" do continue
        // Members are labelled by their enum: a flags field's is its bit_set's element.
        ti := reflect.struct_field_by_name(Entity, name).type
        if bs, ok := runtime.type_info_base(ti).variant.(runtime.Type_Info_Bit_Set); ok do ti = bs.elem
        strings.write_string(&b, " = ")
        ms := members
        first := true
        for m in strings.split_iterator(&ms, "|") {
            if !first do strings.write_string(&b, " / ")
            first = false
            strings.write_string(&b, param_member_label(param_type_name(ti), strings.trim_space(m)))
        }
    }
    return strings.to_string(b)
}

// Whether a field shows: not `hidden`, and matching the search (its id, its label in any language, or its value).
@(private="file")
param_field_shown :: proc(owner_type: string, field: reflect.Struct_Field, value: any, tags: []string, filter: string) -> bool {
    if contains(tags, "hidden") do return false
    if filter == "" do return true
    if search_matches(field.name, filter) do return true
    if search_matches(param_field_label(owner_type, field.name, tags), filter) do return true
    if owner_type == "" {
        for l in entity_field_labels(field.name) do if l != "" && search_matches(l, filter) do return true
    }
    return param_value_matches(field.type, rawptr(uintptr(value.data) + field.offset), filter)
}

// A field is also found by its value where that's text: a string or inline text (a name, an asset key), an
// enum's choice, or the flags that are set, by id or by label in any language. Numbers aren't searched:
// "1" would match half the fields.
@(private="file")
param_value_matches :: proc(ti: ^runtime.Type_Info, data: rawptr, filter: string) -> bool {
    #partial switch v in runtime.type_info_base(ti).variant {
    case runtime.Type_Info_String:
        return search_matches((^string)(data)^, filter)
    case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
        text, ok := sbuf_any_str(any{data, ti.id})
        return ok && search_matches(text, filter)
    case runtime.Type_Info_Enum:
        name, _ := reflect.enum_name_from_value_any(any{data, ti.id})
        return param_member_matches(param_type_name(ti), name, filter)
    case runtime.Type_Info_Bit_Set:
        // Bit j is the enum's j-th member, as ui_param_bitset draws them.
        for name, j in reflect.enum_field_names(v.elem.id) {
            if ([^]u8)(data)[j / 8] & (1 << u32(j % 8)) == 0 do continue
            if param_member_matches(param_type_name(v.elem), name, filter) do return true
        }
    }
    return false
}

@(private="file")
param_member_matches :: proc(type_name, member, filter: string) -> bool {
    if search_matches(member, filter) do return true
    for l in entity_flag_item_labels(type_name, member) do if l != "" && search_matches(l, filter) do return true
    return false
}

// Whether two values of type `ti` are the same as the user sees them: text by content (a string's
// pointer and an inline buffer's unused bytes don't count), structs member by member, anything else
// byte for byte.
param_value_equal :: proc(ti: ^runtime.Type_Info, a, b: rawptr) -> bool {
    #partial switch _ in runtime.type_info_base(ti).variant {
    case runtime.Type_Info_String:
        return (^string)(a)^ == (^string)(b)^
    case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
        sa, _ := sbuf_any_str(any{a, ti.id})
        sb, _ := sbuf_any_str(any{b, ti.id})
        return sa == sb
    case runtime.Type_Info_Struct:
        for i in 0 ..< reflect.struct_field_count(ti.id) {
            f := reflect.struct_field_at(ti.id, i)
            if !param_value_equal(f.type, rawptr(uintptr(a) + f.offset), rawptr(uintptr(b) + f.offset)) do return false
        }
        return true
    }
    return mem.compare_ptrs(a, b, ti.size) == 0
}

// Multi-edit: applies to `dst` what changed between `before` and `after` (the active value, edited this
// frame), and only that: one component of a vector, the flags that were toggled, a whole field otherwise.
// So dragging X on several entities leaves their own Y and Z, and toggling one flag leaves the others.
// Skips `hidden` fields and any with a tag in `skip` (e.g. "identity", so names stay unique).
param_apply_changes :: proc(type: typeid, dst, before, after: rawptr, skip: []string) {
    struct_tags := reflect.struct_field_tags(type)
    fields: for i in 0 ..< reflect.struct_field_count(type) {
        tags := param_field_tags(struct_tags[i])
        if contains(tags, "hidden") do continue
        for t in skip do if contains(tags, t) do continue fields

        f := reflect.struct_field_at(type, i)
        b := rawptr(uintptr(before) + f.offset)
        a := rawptr(uintptr(after)  + f.offset)
        d := rawptr(uintptr(dst)    + f.offset)
        if param_value_equal(f.type, b, a) do continue

        #partial switch v in runtime.type_info_base(f.type).variant {
        case runtime.Type_Info_Array:
            for j in 0 ..< v.count {
                o := uintptr(j * v.elem_size)
                if mem.compare_ptrs(rawptr(uintptr(b) + o), rawptr(uintptr(a) + o), v.elem_size) != 0 {
                    mem.copy(rawptr(uintptr(d) + o), rawptr(uintptr(a) + o), v.elem_size)
                }
            }
        case runtime.Type_Info_Bit_Set:
            for j in 0 ..< f.type.size {
                bb := ([^]u8)(b)[j]
                ab := ([^]u8)(a)[j]
                db := &([^]u8)(d)[j]
                changed := ab ~ bb
                db^ = (db^ &~ changed) | (ab & changed)
            }
        case:
            mem.copy(d, a, f.type.size)
        }
    }
}

// An RGB colour: swatch + picker, always shown and edited as sRGB (what the swatch displays).
//   `widget:color`        — stored as sRGB too (a display colour, e.g. the background): edited as-is.
//   `widget:linear_color` — stored linear (a light's colour, which the shader multiplies): converted for
//                           the picker and back only when the user changes it, so it doesn't drift.
ui_param_color :: proc(name: string, value: ^[3]f32, linear: bool, options := DEFAULT_PARAM_UI_OPTIONS) {
    ui_param_label(name, options)
    im.BeginDisabled(options.readonly)
    if linear {
        shown := [3]f32{linear_to_srgb(value.r), linear_to_srgb(value.g), linear_to_srgb(value.b)}
        if im.ColorEdit3(fmt.ctprintf("##%s", name), &shown) {
            value^ = {srgb_to_linear(shown.r), srgb_to_linear(shown.g), srgb_to_linear(shown.b)}
        }
    } else {
        im.ColorEdit3(fmt.ctprintf("##%s", name), value)
    }
    im.EndDisabled()
}
