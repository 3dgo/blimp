package blimp

import "core:fmt"
import "core:strings"
import im "lib:odin-imgui"

// The in-engine entity-schema editor. Edits schema_doc (loaded from entity_schema.ini); Save
// writes the INI and Apply & Restart rebuilds + relaunches so the new struct takes effect.
// Builtin rows are locked. Text edits go through Edit_Buf. Fields, Groups and Types are tabs under a
// fixed toolbar; each item is a collapsing row (display name, then id and type dim in a shared column)
// that opens into a bordered card of labelled blocks, with aligned label -> input rows.

// The form's label column (ui_label_column over FORM_LABELS), measured once per draw.
@(private = "file") form_label_w: f32

@(private = "file")
FORM_LABELS :: [?]Loc_ID{
    .Schema_Prop_Id, .Schema_Prop_Type, .Schema_Prop_Default, .Schema_Prop_Tags, .Schema_Prop_Widget,
    .Schema_Prop_Note, .Schema_Prop_Section, .Schema_Prop_English, .Schema_Prop_Chinese, .Schema_Prop_Tip_En,
    .Schema_Prop_Tip_Zh, .Schema_Prop_Condition, .Schema_Prop_Effect_En, .Schema_Prop_Effect_Zh,
    .Schema_Prop_Name, .Schema_Kind,
}


ui_draw_schema_editor :: proc() {
    if !schema_doc.loaded do schema_doc_load()

    if im.Begin(tr(.Win_Schema_Editor), &ui.show_schema_editor) {
        ui_schema_toolbar()
        labels := FORM_LABELS
        form_label_w = ui_label_column(labels[:])

        // Tabs, so it's always plain which part of the schema is open; the toolbar stays above them.
        if im.BeginTabBar("schema_tabs") {
            sections := schema_doc_sections()
            n_types := 0
            for &t in schema_doc.types do if !_is_section_enum(&t) do n_types += 1
            if im.BeginTabItem(fmt.ctprintf("%s  %d###tab_fields", tr(.Schema_Fields), len(schema_doc.fields))) {
                ui_schema_body("fields", ui_schema_fields)
                im.EndTabItem()
            }
            if sections != nil && im.BeginTabItem(fmt.ctprintf("%s  %d###tab_groups", tr(.Schema_Groups), len(sections.members))) {
                ui_schema_body("groups", ui_schema_groups)
                im.EndTabItem()
            }
            if im.BeginTabItem(fmt.ctprintf("%s  %d###tab_types", tr(.Schema_Types), n_types)) {
                ui_schema_body("types", ui_schema_types)
                im.EndTabItem()
            }
            im.EndTabBar()
        }
    }
    im.End()
}

// A tab's contents, scrolling under the fixed toolbar and tab bar.
@(private = "file")
ui_schema_body :: proc(id: cstring, draw: proc()) {
    if im.BeginChild(id) do draw()
    im.EndChild()
}

@(private = "file")
ui_schema_fields :: proc() {
    im.PushTextWrapPos(0)
    im.TextDisabled("%s", tr(.Schema_Rename_Hint))
    im.PopTextWrapPos()
    im.Dummy({0, 4 * app.display_scale})

    // Names in one column and id · type in the next, so the list reads like a table.
    name_w: f32
    for &f in schema_doc.fields do name_w = max(name_w, im.CalcTextSize(fmt.ctprintf("%s", ui_schema_name(&f.en, &f.zh, &f.id))).x)

    remove_field, move_from, move_dir := -1, -1, 0
    for &f, i in schema_doc.fields {
        im.PushIDInt(i32(i))
        if ui_card_header(ui_schema_name(&f.en, &f.zh, &f.id), fmt.tprintf("%s  ·  %s", edit_buf_str(&f.id), edit_buf_str(&f.type)), f.builtin, name_w) {
            ui_card_begin()
            ui_heading(tr(.Schema_Block_Definition))
            ui_form_input(tr(.Schema_Prop_Id), "id", &f.id, f.builtin)
            ui_form_type_combo(tr(.Schema_Prop_Type), "type", &f.type, f.builtin)
            ui_form_input(tr(.Schema_Prop_Default), "default", &f.default)
            ui_form_tags(&f)
            ui_form_widget_combo(&f)
            ui_form_input(tr(.Schema_Prop_Note), "note", &f.note)

            ui_heading(tr(.Schema_Block_Inspector))
            ui_form_section_combo(&f.section)   // presentation only, so builtin fields can move too
            ui_form_input(tr(.Schema_Prop_English), "en", &f.en)
            ui_form_input(tr(.Schema_Prop_Chinese), "zh", &f.zh)
            ui_form_input(tr(.Schema_Prop_Tip_En), "tip_en", &f.tip_en)
            ui_form_input(tr(.Schema_Prop_Tip_Zh), "tip_zh", &f.tip_zh)

            ui_heading(tr(.Schema_Prop_When))
            ui_form_uses(&f)

            if m, r := ui_card_footer(len(schema_doc.fields), i, !f.builtin); m != 0 {
                move_from, move_dir = i, m
            } else if r {
                remove_field = i
            }
            ui_card_end()
        }
        im.PopID()
    }
    if remove_field >= 0 do ordered_remove(&schema_doc.fields, remove_field)
    if move_from >= 0 {
        i, j := move_from, move_from + move_dir
        schema_doc.fields[i], schema_doc.fields[j] = schema_doc.fields[j], schema_doc.fields[i]
    }

    im.Dummy({0, 4 * app.display_scale})
    if im.Button(fmt.ctprintf("%s  %s", ICON_ADD, tr(.Schema_Add_Field))) {
        f: Doc_Field
        edit_buf_set(&f.id, "new_field")
        edit_buf_set(&f.type, "f32")
        append(&schema_doc.fields, f)
    }
}

// The members of the section enum: the inspector's sections, in order.
@(private = "file")
ui_schema_groups :: proc() {
    sections := schema_doc_sections()
    if sections == nil do return
    name_w: f32
    for &m in sections.members do name_w = max(name_w, im.CalcTextSize(fmt.ctprintf("%s", ui_schema_name(&m.en, &m.zh, &m.id))).x)

    remove_group := -1
    for &m, i in sections.members {
        im.PushIDInt(i32(i))
        if ui_card_header(ui_schema_name(&m.en, &m.zh, &m.id), edit_buf_str(&m.id), false, name_w) {
            ui_card_begin()
            old_id := strings.clone(edit_buf_str(&m.id), context.temp_allocator)
            ui_form_input(tr(.Schema_Prop_Id), "gid", &m.id)
            if new_id := edit_buf_str(&m.id); new_id != old_id do schema_doc_rename_section(old_id, new_id)
            ui_form_input(tr(.Schema_Prop_English), "gen", &m.en)
            ui_form_input(tr(.Schema_Prop_Chinese), "gzh", &m.zh)
            ui_form_input(tr(.Schema_Prop_Note), "gnote", &m.note)
            if mv, r := ui_card_footer(len(sections.members), i, true); mv != 0 {
                j := i + mv
                sections.members[i], sections.members[j] = sections.members[j], sections.members[i]
            } else if r {
                remove_group = i
            }
            ui_card_end()
        }
        im.PopID()
    }
    if remove_group >= 0 {
        // Its fields move to the top, above the sections.
        id := strings.clone(edit_buf_str(&sections.members[remove_group].id), context.temp_allocator)
        ordered_remove(&sections.members, remove_group)
        schema_doc_rename_section(id, "")
    }

    im.Dummy({0, 4 * app.display_scale})
    if im.Button(fmt.ctprintf("%s  %s", ICON_ADD, tr(.Schema_Add_Group))) {
        id := "Group"
        for n := 2; schema_doc_is_section(id); n += 1 do id = fmt.tprintf("Group_%d", n)
        item: Doc_Item
        edit_buf_set(&item.id, id)
        append(&sections.members, item)
    }
}

// Enum / flags / struct types (the section enum is edited as Groups).
@(private = "file")
ui_schema_types :: proc() {
    name_w: f32
    for &t in schema_doc.types do if !_is_section_enum(&t) do name_w = max(name_w, im.CalcTextSize(fmt.ctprintf("%s", edit_buf_str(&t.name))).x)

    remove_type := -1
    for &t, i in schema_doc.types {
        if _is_section_enum(&t) do continue
        im.PushIDInt(i32(i))
        if ui_card_header(edit_buf_str(&t.name), doc_kind_word(t.kind), t.builtin, name_w) {
            ui_card_begin()
            ui_form_input(tr(.Schema_Prop_Name), "name", &t.name, t.builtin)
            ui_form_kind_combo(&t.kind, t.builtin)
            ui_form_input(tr(.Schema_Prop_Note), "tnote", &t.note)

            ui_heading(tr(.Schema_Members))
            locked := t.builtin
            remove_member := -1
            for &m, mi in t.members {
                im.PushIDInt(i32(mi))
                ui_card_begin(inner = true)
                im.TextColored(UI_COLOR_ACCENT, "%s", fmt.ctprintf("%s", ui_schema_name(&m.en, &m.zh, &m.id)))
                im.SameLine()
                im.TextDisabled("%s", fmt.ctprintf("%s", edit_buf_str(&m.id)))
                if !locked && ui_button_right(ICON_DELETE, tr(.Schema_Remove), same_line = true) do remove_member = mi
                ui_form_input(tr(.Schema_Prop_Id), "mid", &m.id, locked)
                if t.kind == .Struct do ui_form_type_combo(tr(.Schema_Prop_Type), "mtype", &m.type, t.builtin)
                ui_form_input(tr(.Schema_Prop_English), "men", &m.en)
                ui_form_input(tr(.Schema_Prop_Chinese), "mzh", &m.zh)
                if t.kind != .Struct {
                    ui_form_input(tr(.Schema_Prop_Tip_En), "mtip_en", &m.tip_en)
                    ui_form_input(tr(.Schema_Prop_Tip_Zh), "mtip_zh", &m.tip_zh)
                }
                if t.kind == .Struct do ui_form_input(tr(.Schema_Prop_Default), "mdef", &m.default)
                ui_form_input(tr(.Schema_Prop_Note), "mnote", &m.note)
                ui_card_end(inner = true)
                im.PopID()
            }
            if remove_member >= 0 do ordered_remove(&t.members, remove_member)
            if !locked && im.SmallButton(fmt.ctprintf("%s  %s", ICON_ADD, tr(.Schema_Add_Member))) {
                item: Doc_Item
                edit_buf_set(&item.id, t.kind == .Struct ? "new_member" : "Member")
                if t.kind == .Struct do edit_buf_set(&item.type, "f32")
                append(&t.members, item)
            }
            if !t.builtin {
                im.Dummy({0, 2 * app.display_scale})
                if ui_button_right(ICON_DELETE, tr(.Schema_Remove_Type)) do remove_type = i
            }
            ui_card_end()
        }
        im.PopID()
    }
    if remove_type >= 0 do ordered_remove(&schema_doc.types, remove_type)

    im.Dummy({0, 4 * app.display_scale})
    if im.Button(fmt.ctprintf("%s  %s", ICON_ADD, tr(.Schema_Add_Type))) {
        t: Doc_Type
        edit_buf_set(&t.name, "NewType")
        t.kind = .Enum
        append(&schema_doc.types, t)
    }
}

@(private = "file")
_is_section_enum :: proc(t: ^Doc_Type) -> bool {
    return t.kind == .Enum && edit_buf_str(&t.name) == SCHEMA_SECTION_ENUM
}

/* ------------------------------ cards ------------------------------ */

// A collapsing row: the display name, then (dim, at a shared column) the id and type, then a lock if built in.
@(private = "file")
ui_card_header :: proc(name, detail: string, builtin: bool, name_w: f32) -> bool {
    open := im.CollapsingHeader(fmt.ctprintf("%s###head", name), {.AllowOverlap})
    im.SameLine(name_w + 3 * im.GetFontSize())
    im.TextDisabled("%s", fmt.ctprintf("%s", detail))
    if builtin {
        im.SameLine()
        im.TextDisabled(ICON_LOCK)
        im.SetItemTooltip("%s", tr(.Schema_Builtin))
    }
    return open
}

// Up / Down on the left, Remove on the right. Returns the move (-1, +1, 0) and whether Remove was clicked.
@(private = "file")
ui_card_footer :: proc(count, i: int, removable: bool) -> (move: int, remove: bool) {
    im.Dummy({0, 4 * app.display_scale})
    im.BeginDisabled(i == 0)
    if im.SmallButton(fmt.ctprintf("%s##up", ICON_ARROW_UP)) do move = -1
    im.EndDisabled()
    im.SetItemTooltip("%s", tr(.Schema_Move_Up))
    im.SameLine()
    im.BeginDisabled(i >= count - 1)
    if im.SmallButton(fmt.ctprintf("%s##down", ICON_ARROW_DOWN)) do move = +1
    im.EndDisabled()
    im.SetItemTooltip("%s", tr(.Schema_Move_Down))
    if removable do remove = ui_button_right(ICON_DELETE, tr(.Schema_Remove), same_line = true)
    return
}

// A small icon + text button at the right edge (of this row, if `same_line`).
@(private = "file")
ui_button_right :: proc(icon: string, label: cstring, same_line := false) -> bool {
    text := fmt.ctprintf("%s  %s", icon, label)
    w := im.CalcTextSize(text).x + 2 * im.GetStyle().FramePadding.x
    if same_line do im.SameLine()
    im.SetCursorPosX(im.GetCursorPosX() + max(im.GetContentRegionAvail().x - w, 0))
    return im.SmallButton(text)
}

/* ------------------------------ pieces ------------------------------ */

@(private = "file")
ui_schema_toolbar :: proc() {
    if im.Button(tr(.Schema_Save)) {
        if ok, msg := schema_doc_validate(); ok {
            schema_doc_save(ENTITY_SCHEMA_PATH)
            edit_buf_set(&ui.schema_status, trs(.Schema_Status_Saved))
        } else {
            edit_buf_set(&ui.schema_status, msg)
        }
    }
    im.SameLine()
    if im.Button(tr(.Schema_Reload)) {
        schema_doc_load()
        edit_buf_set(&ui.schema_status, trs(.Schema_Status_Reloaded))
    }
    im.SameLine()
    if im.Button(tr(.Schema_Apply)) {
        if ok, msg := schema_doc_validate(); ok {
            if schema_doc_save(ENTITY_SCHEMA_PATH) {
                if !app_rebuild_and_restart() do edit_buf_set(&ui.schema_status, trs(.Schema_Status_Build_Failed))
            }
        } else {
            edit_buf_set(&ui.schema_status, msg)
        }
    }
    if status := edit_buf_str(&ui.schema_status); status != "" {
        im.TextColored(UI_COLOR_WARNING, "%s", fmt.ctprintf("%s", status))
    }
}

// A form row: left-aligned label, then a full-width input starting at a fixed column.
@(private = "file")
ui_form_input :: proc(label: cstring, key: string, b: ^Edit_Buf, readonly := false) {
    ui_param_label(string(label), {label_w = form_label_w})
    im.BeginDisabled(readonly)
    im.InputText(fmt.ctprintf("##%s", key), cstring(raw_data(b.data[:])), EDIT_BUF_LEN)
    im.EndDisabled()
}

// A field's `when` entries, each a panel: the condition, and what the field does while it holds.
@(private = "file")
ui_form_uses :: proc(f: ^Doc_Field) {
    remove := -1
    for &u, i in f.uses {
        im.PushIDInt(i32(i))
        ui_card_begin(inner = true)
        ui_form_input(tr(.Schema_Prop_Condition), "when", &u.cond)
        ui_form_input(tr(.Schema_Prop_Effect_En), "when_en", &u.en)
        ui_form_input(tr(.Schema_Prop_Effect_Zh), "when_zh", &u.zh)
        if ui_button_right(ICON_DELETE, tr(.Schema_Remove)) do remove = i
        ui_card_end(inner = true)
        im.PopID()
    }
    if remove >= 0 do ordered_remove(&f.uses, remove)
    if im.SmallButton(fmt.ctprintf("%s  %s", ICON_ADD, tr(.Schema_Add_When))) do append(&f.uses, Doc_Use{})
}

@(private = "file")
ui_form_type_combo :: proc(label: cstring, key: string, b: ^Edit_Buf, readonly: bool) {
    ui_param_label(string(label), {label_w = form_label_w})
    im.BeginDisabled(readonly)
    cur := edit_buf_str(b)
    if im.BeginCombo(fmt.ctprintf("##%s", key), fmt.ctprintf("%s", cur)) {
        for s in SCHEMA_USER_TYPES {
            if im.Selectable(fmt.ctprintf("%s", s), s == cur) do edit_buf_set(b, s)
        }
        for &t in schema_doc.types {
            opt := fmt.tprintf("%s.%s", doc_kind_word(t.kind), edit_buf_str(&t.name))
            if im.Selectable(fmt.ctprintf("%s", opt), opt == cur) do edit_buf_set(b, opt)
        }
        im.EndCombo()
    }
    im.EndDisabled()
}

// A form row picking a field's inspector section: a member of the section enum, or none (drawn first,
// above the sections).
@(private = "file")
ui_form_section_combo :: proc(b: ^Edit_Buf) {
    ui_param_label(string(tr(.Schema_Prop_Section)), {label_w = form_label_w})
    cur := edit_buf_str(b)
    sections := schema_doc_sections()
    shown := cur
    if cur == "" do shown = trs(.Schema_Section_None)
    else if sections != nil {
        for &m in sections.members do if edit_buf_str(&m.id) == cur do shown = ui_schema_name(&m.en, &m.zh, &m.id)
    }
    if im.BeginCombo("##section", fmt.ctprintf("%s", shown)) {
        if im.Selectable(tr(.Schema_Section_None), cur == "") do edit_buf_set(b, "")
        if sections != nil {
            for &m in sections.members {
                id := edit_buf_str(&m.id)
                if im.Selectable(fmt.ctprintf("%s##%s", ui_schema_name(&m.en, &m.zh, &m.id), id), id == cur) do edit_buf_set(b, id)
            }
        }
        im.EndCombo()
    }
}

// A form row of toggles, one per flag tag. Locked on builtin fields: the engine relies on theirs.
@(private = "file")
ui_form_tags :: proc(f: ^Doc_Field) {
    ui_param_label(string(tr(.Schema_Prop_Tags)), {label_w = form_label_w})
    im.BeginDisabled(f.builtin)
    for ft, i in SCHEMA_FLAG_TAGS {
        if i > 0 do im.SameLine()
        im.Checkbox(tr(ft.label), &f.flags[i])
    }
    im.EndDisabled()
}

// A form row picking the field's inspector widget among those that fit its type. Skipped when none
// fits and none is set.
@(private = "file")
ui_form_widget_combo :: proc(f: ^Doc_Field) {
    type := edit_buf_str(&f.type)
    cur := edit_buf_str(&f.widget)
    any_fits := false
    for w in schema_widgets do if schema_widget_fits(w.name, type) { any_fits = true; break }
    if !any_fits && cur == "" do return

    ui_param_label(string(tr(.Schema_Prop_Widget)), {label_w = form_label_w})
    im.BeginDisabled(f.builtin)
    shown := cur == "" ? trs(.Schema_Widget_Default) : cur
    for w in schema_widgets do if w.name == cur do shown = trs(w.label)
    if im.BeginCombo("##widget", fmt.ctprintf("%s", shown)) {
        if im.Selectable(tr(.Schema_Widget_Default), cur == "") do edit_buf_set(&f.widget, "")
        for w in schema_widgets do if schema_widget_fits(w.name, type) {
            if im.Selectable(fmt.ctprintf("%s##%s", trs(w.label), w.name), w.name == cur) do edit_buf_set(&f.widget, w.name)
        }
        im.EndCombo()
    }
    im.EndDisabled()
}

// A form row selecting a type's kind (enum / flags / struct).
@(private = "file")
ui_form_kind_combo :: proc(kind: ^Doc_Type_Kind, readonly: bool) {
    ui_param_label(string(tr(.Schema_Kind)), {label_w = form_label_w})
    im.BeginDisabled(readonly)
    labels := [Doc_Type_Kind]cstring{ .Enum = tr(.Schema_Kind_Enum), .Flags = tr(.Schema_Kind_Flags), .Struct = tr(.Schema_Kind_Struct) }
    if im.BeginCombo("##kind", labels[kind^]) {
        for k in Doc_Type_Kind {
            if im.Selectable(labels[k], k == kind^) do kind^ = k
        }
        im.EndCombo()
    }
    im.EndDisabled()
}

// Current-language display name (English/Chinese), falling back to the id.
@(private = "file")
ui_schema_name :: proc(en, zh, id: ^Edit_Buf) -> string {
    s := loc_lang == .ZH ? edit_buf_str(zh) : edit_buf_str(en)
    if s == "" do s = edit_buf_str(id)
    return s
}
