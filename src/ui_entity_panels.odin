package blimp

import "core:fmt"
import "core:mem"
import "core:strings"
import hm "core:container/handle_map"
import im "lib:odin-imgui"

// A world window's entity list and inspector (World_Host, ui_view.odin): docked beside its viewport and
// showing that view's world (the running copy while it plays). Each world keeps its own selection. The
// toolbar's panels button hides both, and the viewport takes their space.

// Draws h's list and inspector, unless they're hidden or the window hasn't docked them yet (so they never
// flash up floating).
ui_draw_entity_panels :: proc(h: ^World_Host) {
    if !h.built || !h.show_panels do return
    w := h.view.world
    if im.Begin(fmt.ctprintf("%s###entity_list%d", tr(.Panel_Entity_List), h.view.id)) do ui_entity_list_body(w, &h.list_search)
    im.End()
    if im.Begin(fmt.ctprintf("%s###entity_inspector%d", tr(.Panel_Entity_Inspector), h.view.id)) do ui_entity_inspector_body(w, &h.inspector_search)
    im.End()
}

// Above an inspector: a line saying edits to `w` won't be kept — a play world (thrown away on Stop) or
// a kit (can't be saved).
ui_world_unsaved_note :: proc(w: ^World) {
    switch {
    case w.play_source != nil: im.TextColored(UI_COLOR_ACCENT, "%s", tr(.Play_Warning))
    case w.save_path == "":    im.TextColored(UI_COLOR_WARNING, "%s", tr(.Inspector_Kit_Warning))
    }
}

// `w` is closing, or its views moved to another world (Play / Stop): a rename in it ends.
ui_entity_rename_forget :: proc(w: ^World) {
    if rename.world == w do rename = {}
}

// Click: just this one. Ctrl+click: toggle it. Shift+click: the range from the anchor (the last
// plain or Ctrl click) to here, in list order; Ctrl+Shift adds the range to the selection.
// Right-click on a row selects it unless it's already selected, then opens the context menu; on empty
// space it opens the menu for the current selection. Paste lands at the centre of a view on the world.
// F2 turns the active entity's row into a text field (ui_entity_rename_begin).
@(private="file")
ui_entity_list_body :: proc(w: ^World, search_buf: ^[64]u8) {
    ui_panel_search_box(search_buf, tr(.Entity_List_Search))
    search := string(cstring(&search_buf[0]))

    // The rows scroll under the search box, which stays put.
    im.BeginChild("##rows")
    defer im.EndChild()

    open_menu := false
    it := hm.iterator_make(&w.entities)
    for e, h in hm.iterate(&it) {
        if rename.world == w && rename.handle == h {
            rename_row(w, h)
            continue
        }
        if !search_matches(sbuf_str(&e.name), search) do continue
        icon, _ := entity_icon(e)
        clicked := ui_icon_selectable(fmt.ctprintf("##e%v", h.idx), icon, sbuf_str(&e.name), e.selected)
        // Double-click frames it in the world's view (the first click already selected it), like F.
        if im.IsItemHovered() && im.IsMouseDoubleClicked(.Left) && !ui.io.KeyCtrl && !ui.io.KeyShift {
            if ev := editor_view_for_world(w); ev != nil do editor_frame_selection(ev)
        }
        if im.IsItemHovered() && im.IsMouseReleased(.Right) {
            if !e.selected do selection_only(w, h)
            open_menu = true
        }
        if !clicked do continue
        world_activate(w)   // interacting with a world makes it the copy/paste target
        ctrl, shift := ui.io.KeyCtrl, ui.io.KeyShift
        switch {
        case shift && selection_has_anchor(w):
            if !ctrl do selection_clear(w)
            // Walk the list: selecting starts at whichever end comes first and stops after the other. Rows
            // the search hides are skipped.
            ends := 0
            rit := hm.iterator_make(&w.entities)
            for re, rh in hm.iterate(&rit) {
                if rh == editor_world(w).select_anchor || rh == h do ends += editor_world(w).select_anchor == h ? 2 : 1
                if ends > 0 && search_matches(sbuf_str(&re.name), search) do selection_set(w, rh, true)
                if ends >= 2 do break
            }
            selection_set(w, h, true)   // the clicked one is active
        case ctrl:
            selection_toggle(w, h)
            editor_world(w).select_anchor = h
        case:
            selection_only(w, h)
            editor_world(w).select_anchor = h
        }
    }

    if !open_menu && im.IsWindowHovered() && im.IsMouseReleased(.Right) do open_menu = true
    if open_menu {
        ev := editor_view_for_world(w)
        ui_context_menu_open(w, ev != nil ? ev.view : nil, ev != nil ? paste_target_point(ev) : {})
    }
    ui_context_menu()
}

// F2 rename, in place in the entity list (Unity's hierarchy). One at a time.
@(private="file")
rename: struct {
    world:  ^World,
    handle: Entity_Handle,
    focus:  bool,       // put the keyboard in the field on its first frame
    buf:    [128]u8,
}

// Starts renaming `w`'s active entity (F2, the right-click menu).
ui_entity_rename_begin :: proc(w: ^World) {
    e, ok := entity_get(w, editor_world(w).active)
    if !ok do return
    rename = {world = w, handle = editor_world(w).active, focus = true}
    copy(rename.buf[:len(rename.buf) - 1], sbuf_str(&e.name))
}

// The field replacing a row. Enter or clicking away keeps the name, Esc cancels. One undo step;
// names stay unique per world.
@(private="file")
rename_row :: proc(w: ^World, h: Entity_Handle) {
    first := rename.focus
    if first do im.SetKeyboardFocusHere()
    rename.focus = false
    im.SetNextItemWidth(-1)
    im.InputText("##rename", cstring(&rename.buf[0]), len(rename.buf), {.EnterReturnsTrue, .AutoSelectAll})
    if first || im.IsItemActive() do return   // the field takes the keyboard from the next frame on

    // Done: Enter or clicking away (keep), or Esc (cancel; ImGui restores the text and deactivates).
    if !im.IsKeyPressed(.Escape, false) {
        if e, ok := entity_get(w, h); ok {
            name := string(cstring(&rename.buf[0]))
            if name != sbuf_str(&e.name) {
                before := e^
                sbuf_set(&e.name, name)
                world_fix_duplicate_name(w, h)
                undo_push_edited(w, h, before)
            }
        }
    }
    rename = {}
}

@(private="file")
selection_has_anchor :: proc(w: ^World) -> bool {
    _, ok := entity_get(w, editor_world(w).select_anchor)
    return ok
}

@(private="file")
ui_entity_inspector_body :: proc(w: ^World, search_buf: ^[64]u8) {
    ui_world_unsaved_note(w)

    e, ok := entity_get(w, editor_world(w).active)
    if !ok do return
    if n := selection_count(w); n > 1 do im.TextDisabled("%s", fmt.ctprintf(string(tr(.Inspector_Multi)), n))

    ui_panel_search_box(search_buf, tr(.Inspector_Search))
    im.Separator()

    // The fields scroll under the header (buttons, search), which stays put.
    im.BeginChild("##fields")
    defer im.EndChild()

    // The rest of the selection: the inspector shows where they differ, and edits apply to them too.
    others := make([dynamic]rawptr, context.temp_allocator)
    for h in selection_handles(w) {
        if h == editor_world(w).active do continue
        if o, found := entity_get(w, h); found do append(&others, o)
    }
    defaults: Entity
    entity_apply_defaults(&defaults)

    opts := DEFAULT_PARAM_UI_OPTIONS
    opts.headerless = true
    opts.filter     = strings.trim_space(string(cstring(&search_buf[0])))
    opts.defaults   = &defaults
    opts.others     = others[:]
    before := e^
    ui_param_struct("entity", Entity, e^, opts)

    // Names stay unique per world. Checked once nothing is being edited — not per keystroke, which
    // would rename "car" to "car_1" mid-word while typing "car_12".
    if !im.IsAnyItemActive() do world_fix_duplicate_name(w, editor_world(w).active)

    // Undo for inspector edits, detected after the fact (the reflection widgets don't report edits):
    // the first frame the entity changes opens one step holding its pre-edit state, and the step stays
    // open while a widget is held, so a whole drag or a typed name is one Ctrl+Z.
    if mem.compare_ptrs(&before, e, size_of(Entity)) != 0 {
        if !ui.inspector_editing {
            undo_push_edited(w, editor_world(w).active, before)
            ui.inspector_editing = true
        }
        // Multi-edit, after the snapshot that covers it: just what changed on the active entity this frame
        // goes to the rest of the selection. Names stay their own.
        for o in others do param_apply_changes(Entity, o, &before, e, {"identity"})
    }
    if !im.IsAnyItemActive() do ui.inspector_editing = false
}

// A panel's search box, full width on its own row (search_matches: Chinese also by pinyin).
@(private="file")
ui_panel_search_box :: proc(buf: ^[64]u8, hint: cstring) {
    im.SetNextItemWidth(-1)
    im.InputTextWithHint("##search", fmt.ctprintf("%s  %s", ICON_SEARCH, hint), cstring(&buf[0]), len(buf))
}

// A one-line selectable with an icon column (blank when `icon` is "") and `name` after it, so names
// line up whether or not a row has an icon. The entity and template lists. `id` is the row's
// "##label", unique in the window. The selectable is the last item, so IsItemHovered still applies.
ui_icon_selectable :: proc(id: cstring, icon, name: string, selected: bool) -> (clicked: bool) {
    clicked = im.Selectable(id, selected)
    mn := im.GetItemRectMin()
    dl := im.GetWindowDrawList()
    text := im.GetColorU32ImVec4(im.GetStyleColorVec4(.Text)^)   // takes style alpha, so it dims when disabled
    if icon != "" do im.DrawList_AddText(dl, mn, text, fmt.ctprintf("%s", icon))
    im.DrawList_AddText(dl, {mn.x + im.GetTextLineHeight() * 1.6, mn.y}, text, fmt.ctprintf("%s", name))
    return
}
