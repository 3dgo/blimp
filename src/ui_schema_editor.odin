package blimp

import "core:fmt"
import "core:strings"
import im "lib:odin-imgui"

// The in-engine entity-schema editor. Edits schema_doc (loaded from entity_schema.ini); Save
// writes the INI and Apply & Restart rebuilds + relaunches so the new struct takes effect.
// Builtin rows are locked. Text edits go through Edit_Buf. Laid out as a form: collapsed cards
// (each header shows the current-language display name + id + type), and inside, aligned
// label -> input rows with breathing room.

@(private = "file") FORM_LABEL_W :: 90   // px (scaled), where inputs start on each form row

ui_draw_schema_editor :: proc() {
    if !schema_doc.loaded do schema_doc_load()

    if im.Begin(tr(.Win_Schema_Editor), &ui.show_schema_editor) {
        ui_schema_toolbar()
        _sep()

        // ---- Fields ----
        im.SeparatorText(tr(.Schema_Fields))
        im.TextDisabled("%s", tr(.Schema_Rename_Hint))
        im.Dummy({0, 4 * app.display_scale})

        remove_field := -1
        for &f, i in schema_doc.fields {
            im.PushIDInt(i32(i))
            name := ui_schema_name(&f.en, &f.zh, &f.id)
            head := fmt.ctprintf("%s      %s  ·  %s%s###f%d",
                name, edit_buf_str(&f.id), edit_buf_str(&f.type),
                f.builtin ? fmt.tprintf("      [%s]", trs(.Schema_Builtin)) : "", i)
            if im.CollapsingHeader(head) {
                im.Indent()
                im.Dummy({0, 2 * app.display_scale})
                ui_form_input(tr(.Schema_Prop_Id), "id", &f.id, f.builtin)
                ui_form_type_combo(tr(.Schema_Prop_Type), "type", &f.type, f.builtin)
                ui_form_section_combo(&f.section)   // presentation only, so builtin fields can move too
                ui_form_tags(&f)
                ui_form_widget_combo(&f)
                ui_form_input(tr(.Schema_Prop_English), "en", &f.en)
                ui_form_input(tr(.Schema_Prop_Chinese), "zh", &f.zh)
                ui_form_input(tr(.Schema_Prop_Default), "default", &f.default)
                ui_form_input(tr(.Schema_Prop_Note), "note", &f.note)

                im.Dummy({0, 4 * app.display_scale})
                if ui_move_buttons(len(schema_doc.fields), i) != 0 {
                    j := i + ui_move_buttons_last
                    schema_doc.fields[i], schema_doc.fields[j] = schema_doc.fields[j], schema_doc.fields[i]
                }
                if !f.builtin {
                    im.SameLine()
                    if im.SmallButton(tr(.Schema_Remove)) do remove_field = i
                }
                im.Unindent()
                im.Dummy({0, 8 * app.display_scale})
            }
            im.PopID()
        }
        if remove_field >= 0 do ordered_remove(&schema_doc.fields, remove_field)

        if im.Button(tr(.Schema_Add_Field)) {
            f: Doc_Field
            edit_buf_set(&f.id, "new_field")
            edit_buf_set(&f.type, "f32")
            append(&schema_doc.fields, f)
        }

        im.Dummy({0, 10 * app.display_scale})

        // ---- Groups: the members of the section enum, i.e. the inspector's sections in order ----
        if sections := schema_doc_sections(); sections != nil {
            im.SeparatorText(tr(.Schema_Groups))
            im.Dummy({0, 4 * app.display_scale})

            remove_group := -1
            for &m, i in sections.members {
                im.PushIDInt(i32(2_000_000 + i))
                head := fmt.ctprintf("%s      %s###g%d", ui_schema_name(&m.en, &m.zh, &m.id), edit_buf_str(&m.id), i)
                if im.CollapsingHeader(head) {
                    im.Indent()
                    im.Dummy({0, 2 * app.display_scale})
                    old_id := strings.clone(edit_buf_str(&m.id), context.temp_allocator)
                    ui_form_input(tr(.Schema_Prop_Id), "gid", &m.id)
                    if new_id := edit_buf_str(&m.id); new_id != old_id do schema_doc_rename_section(old_id, new_id)
                    ui_form_input(tr(.Schema_Prop_English), "gen", &m.en)
                    ui_form_input(tr(.Schema_Prop_Chinese), "gzh", &m.zh)
                    ui_form_input(tr(.Schema_Prop_Note), "gnote", &m.note)

                    im.Dummy({0, 4 * app.display_scale})
                    if ui_move_buttons(len(sections.members), i) != 0 {
                        j := i + ui_move_buttons_last
                        sections.members[i], sections.members[j] = sections.members[j], sections.members[i]
                    }
                    im.SameLine()
                    if im.SmallButton(tr(.Schema_Remove)) do remove_group = i
                    im.Unindent()
                    im.Dummy({0, 8 * app.display_scale})
                }
                im.PopID()
            }
            if remove_group >= 0 {
                // Its fields move to the top, above the sections.
                id := strings.clone(edit_buf_str(&sections.members[remove_group].id), context.temp_allocator)
                ordered_remove(&sections.members, remove_group)
                schema_doc_rename_section(id, "")
            }

            if im.Button(tr(.Schema_Add_Group)) {
                id := "Group"
                for n := 2; schema_doc_is_section(id); n += 1 do id = fmt.tprintf("Group_%d", n)
                item: Doc_Item
                edit_buf_set(&item.id, id)
                append(&sections.members, item)
            }

            im.Dummy({0, 10 * app.display_scale})
        }

        // ---- Types (enum / flags / struct; the section enum is edited above, as Groups) ----
        im.SeparatorText(tr(.Schema_Types))
        im.Dummy({0, 4 * app.display_scale})

        remove_type := -1
        for &t, i in schema_doc.types {
            if t.kind == .Enum && edit_buf_str(&t.name) == SCHEMA_SECTION_ENUM do continue
            im.PushIDInt(i32(1_000_000 + i))
            head := fmt.ctprintf("%s      [%s]%s###t%d",
                edit_buf_str(&t.name), doc_kind_word(t.kind),
                t.builtin ? fmt.tprintf("      [%s]", trs(.Schema_Builtin)) : "", i)
            if im.CollapsingHeader(head) {
                im.Indent()
                im.Dummy({0, 2 * app.display_scale})
                ui_form_input(tr(.Schema_Prop_Name), "name", &t.name, t.builtin)
                ui_form_kind_combo(&t.kind, t.builtin)
                ui_form_input(tr(.Schema_Prop_Note), "tnote", &t.note)

                im.Dummy({0, 4 * app.display_scale})
                im.SeparatorText(tr(.Schema_Members))
                members_locked := t.builtin
                remove_member := -1
                for &m, mi in t.members {
                    im.PushIDInt(i32(mi))
                    mname := ui_schema_name(&m.en, &m.zh, &m.id)
                    im.TextUnformatted(fmt.ctprintf("%s  ·  %s", mname, edit_buf_str(&m.id)))
                    im.Indent()
                    ui_form_input(tr(.Schema_Prop_Id), "mid", &m.id, members_locked)
                    if t.kind == .Struct {
                        ui_form_type_combo(tr(.Schema_Prop_Type), "mtype", &m.type, t.builtin)
                    }
                    ui_form_input(tr(.Schema_Prop_English), "men", &m.en)
                    ui_form_input(tr(.Schema_Prop_Chinese), "mzh", &m.zh)
                    if t.kind == .Struct {
                        ui_form_input(tr(.Schema_Prop_Default), "mdef", &m.default)
                    }
                    ui_form_input(tr(.Schema_Prop_Note), "mnote", &m.note)
                    if !members_locked {
                        if im.SmallButton(tr(.Schema_Remove)) do remove_member = mi
                    }
                    im.Unindent()
                    im.Dummy({0, 4 * app.display_scale})
                    im.PopID()
                }
                if remove_member >= 0 do ordered_remove(&t.members, remove_member)

                if !members_locked {
                    if im.SmallButton(tr(.Schema_Add_Member)) {
                        item: Doc_Item
                        edit_buf_set(&item.id, t.kind == .Struct ? "new_member" : "Member")
                        if t.kind == .Struct do edit_buf_set(&item.type, "f32")
                        append(&t.members, item)
                    }
                }
                if !t.builtin {
                    im.SameLine()
                    if im.SmallButton(tr(.Schema_Remove_Type)) do remove_type = i
                }
                im.Unindent()
                im.Dummy({0, 8 * app.display_scale})
            }
            im.PopID()
        }
        if remove_type >= 0 do ordered_remove(&schema_doc.types, remove_type)

        if im.Button(tr(.Schema_Add_Type)) {
            t: Doc_Type
            edit_buf_set(&t.name, "NewType")
            t.kind = .Enum
            append(&schema_doc.types, t)
        }
    }
    im.End()
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
        im.TextColored({1, 0.55, 0.4, 1}, "%s", fmt.ctprintf("%s", status))
    }
}

// A form row: left-aligned label, then a full-width input starting at a fixed column.
@(private = "file")
ui_form_input :: proc(label: cstring, key: string, b: ^Edit_Buf, readonly := false) {
    ui_param_label(string(label), {label_w = FORM_LABEL_W * app.display_scale})
    im.BeginDisabled(readonly)
    im.InputText(fmt.ctprintf("##%s", key), cstring(raw_data(b.data[:])), EDIT_BUF_LEN)
    im.EndDisabled()
}

@(private = "file")
ui_form_type_combo :: proc(label: cstring, key: string, b: ^Edit_Buf, readonly: bool) {
    ui_param_label(string(label), {label_w = FORM_LABEL_W * app.display_scale})
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
    ui_param_label(string(tr(.Schema_Prop_Section)), {label_w = FORM_LABEL_W * app.display_scale})
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
    ui_param_label(string(tr(.Schema_Prop_Tags)), {label_w = FORM_LABEL_W * app.display_scale})
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

    ui_param_label(string(tr(.Schema_Prop_Widget)), {label_w = FORM_LABEL_W * app.display_scale})
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
    ui_param_label(string(tr(.Schema_Kind)), {label_w = FORM_LABEL_W * app.display_scale})
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

// Up/Down buttons; returns non-zero when a move is requested, with the target offset in
// ui_move_buttons_last (-1 up, +1 down). Buttons are disabled at the ends.
@(private = "file") ui_move_buttons_last: int
@(private = "file")
ui_move_buttons :: proc(count, i: int) -> int {
    moved := 0
    im.BeginDisabled(i == 0)
    if im.SmallButton(tr(.Schema_Move_Up)) { moved = 1; ui_move_buttons_last = -1 }
    im.EndDisabled()
    im.SameLine()
    im.BeginDisabled(i >= count - 1)
    if im.SmallButton(tr(.Schema_Move_Down)) { moved = 1; ui_move_buttons_last = +1 }
    im.EndDisabled()
    return moved
}

@(private = "file")
_sep :: proc() {
    im.Dummy({0, 4 * app.display_scale})
    im.Separator()
    im.Dummy({0, 4 * app.display_scale})
}
