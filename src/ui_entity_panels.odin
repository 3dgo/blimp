package blimp

import "core:fmt"
import "core:mem"
import "core:strings"
import vmem "core:mem/virtual"
import hm "core:container/handle_map"
import im "lib:odin-imgui"

// Entity list and inspector windows, any number of each. A panel either follows the active world
// (the viewport you last focused) or is pinned to one world via the combo at its top. Each world
// keeps its own selection, so a pinned panel keeps showing its world's selection while you work
// in another. Closing a panel removes it.
Entity_Panel_Kind :: enum { List, Inspector }

Entity_Panel :: struct {
    kind:   Entity_Panel_Kind,
    id:     u32,      // window id suffix: "###entity_list<id>" / "###entity_inspector<id>"
    pinned: ^World,   // nil = follow the active world
    owner:  ^Render_View,   // non-nil = docked inside that view's world window and closes with it (World_Host in
                            // ui_view.odin). Layout + lifetime only: what it shows is still `pinned` (starts as that
                            // window's world), re-targetable via the combo like any panel.
    open:   bool,
    search: [64]u8,   // the search box's text (NUL-terminated): entity names in a list, fields in an inspector
}

PANEL_WINDOW_SIZE :: [2]f32{360, 480}   // first-open size of a floating panel (× display scale)

// Opens another panel; `owner` non-nil docks it inside that view's world window. Returns its id.
ui_entity_panel_new :: proc(kind: Entity_Panel_Kind, owner: ^Render_View = nil) -> u32 {
    ui.next_panel_id += 1
    pinned := owner != nil ? owner.world : nil   // a world window's panels start pinned to its world
    append(&ui.panels, Entity_Panel{kind = kind, id = ui.next_panel_id, pinned = pinned, owner = owner, open = true})
    return ui.next_panel_id
}

// Above an inspector: a line saying edits to `w` won't be kept — a play world (thrown away on Stop) or
// a kit (can't be saved).
ui_world_unsaved_note :: proc(w: ^World) {
    switch {
    case w.play_source != nil: im.TextColored({0.45, 0.7, 1, 1}, "%s", tr(.Play_Warning))
    case w.save_path == "":    im.TextColored({1, 0.75, 0.3, 1}, "%s", tr(.Inspector_Kit_Warning))
    }
}

// Views switched from one world to another (Play / Stop, world_play.odin). Editor state pinned to the
// old world follows, and drags in progress on those views end: they were editing the world being left.
ui_retarget_world :: proc(from, to: ^World) {
    if rename.world == from do rename = {}
    for &p in ui.panels do if p.pinned == from do p.pinned = to
    ui_world_settings_retarget(from, to)
    ui_context_menu_forget(from, nil)
    for v in views do if v.world == to {
        ev := editor_view(v)
        ev.gizmo.drag, ev.gizmo.pushed = .None, false
        ev.marquee = {}
    }
}

// A world is closing: panels pinned to it go back to following.
ui_forget_world :: proc(w: ^World) {
    ui_world_settings_forget(w)
    ui_bake_forget(w)
    ui_retro_forget(w)
    ui_context_menu_forget(w, nil)
    for &p in ui.panels do if p.pinned == w do p.pinned = nil
    if rename.world == w do rename = {}
    ui_unsaved_forget_world(w)
}

ui_draw_entity_panels :: proc() {
    for i := 0; i < len(ui.panels); i += 1 {
        p := &ui.panels[i]
        if !p.open {
            ordered_remove(&ui.panels, i)
            i -= 1
            continue
        }
        ui_draw_entity_panel(p)
    }
}

@(private="file")
ui_draw_entity_panel :: proc(p: ^Entity_Panel) {
    // A world window's own panels wait until it has docked them, so they never flash up floating.
    if p.owner != nil {
        h := ui_host_find(p.owner)
        if h == nil || !h.built do return
    }

    w := p.pinned != nil ? p.pinned : active_world()   // nil: following, and nothing open

    base := p.kind == .List ? "entity_list" : "entity_inspector"
    name := p.kind == .List ? tr(.Menu_Entity_List) : tr(.Menu_Entity_Inspector)
    if p.owner == nil {
        s := app.dispaly_scale
        im.SetNextWindowSize({PANEL_WINDOW_SIZE.x * s, PANEL_WINDOW_SIZE.y * s}, .FirstUseEver)
    }
    if im.Begin(fmt.ctprintf("%s — %s###%s%d", name, w != nil ? w.title : "—", base, p.id), &p.open) {
        ui_panel_target_combo(p)
        im.Separator()
        if w == nil {
            im.TextDisabled("%s", tr(.Panel_No_World))
            im.End()
            return
        }
        switch p.kind {
        case .List:      ui_entity_list_body(p, w)
        case .Inspector: ui_entity_inspector_body(p, w)
        }
    }
    im.End()
}

// "Follow active (castle.level)" / one entry per open world.
@(private="file")
ui_panel_target_combo :: proc(p: ^Entity_Panel) {
    active := active_world()
    preview := p.pinned == nil \
        ? fmt.ctprintf("%s (%s)", tr(.Panel_Follow), active != nil ? active.title : "—") \
        : fmt.ctprintf("%s", p.pinned.title)
    im.SetNextItemWidth(-1)
    if im.BeginCombo("##target", preview, {}) {
        if im.Selectable(tr(.Panel_Follow), p.pinned == nil) do p.pinned = nil
        for w, i in worlds {
            im.PushIDInt(i32(i))
            if im.Selectable(fmt.ctprintf("%s", w.title), p.pinned == w) do p.pinned = w
            im.PopID()
        }
        im.EndCombo()
    }
}

// Click: just this one. Ctrl+click: toggle it. Shift+click: the range from the anchor (the last
// plain or Ctrl click) to here, in list order; Ctrl+Shift adds the range to the selection.
// Right-click on a row selects it unless it's already selected, then opens the context menu; on empty
// space it opens the menu for the current selection. Paste lands at the centre of a view on the world.
// F2 turns the active entity's row into a text field (ui_entity_rename_begin).
@(private="file")
ui_entity_list_body :: proc(p: ^Entity_Panel, w: ^World) {
    ui_panel_search_box(p, tr(.Entity_List_Search))
    search := string(cstring(&p.search[0]))

    // The rows scroll under the search box, which stays put.
    im.BeginChild("##rows")
    defer im.EndChild()

    open_menu := false
    it := hm.iterator_make(&w.entities)
    for e, h in hm.iterate(&it) {
        if rename.world == w && rename.handle == h && (rename.panel == 0 || rename.panel == p.id) {
            rename_row(p, w, h)
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
                if rh == w.select_anchor || rh == h do ends += w.select_anchor == h ? 2 : 1
                if ends > 0 && search_matches(sbuf_str(&re.name), search) do selection_set(w, rh, true)
                if ends >= 2 do break
            }
            selection_set(w, h, true)   // the clicked one is active
        case ctrl:
            selection_toggle(w, h)
            w.select_anchor = h
        case:
            selection_only(w, h)
            w.select_anchor = h
        }
    }

    if !open_menu && im.IsWindowHovered() && im.IsMouseReleased(.Right) do open_menu = true
    if open_menu {
        v := ui_first_view_of(w)
        ui_context_menu_open(w, v, v != nil ? paste_target_point(editor_view(v)) : {})
    }
    ui_context_menu()
}

// F2 rename, in place in the entity list (Unity's hierarchy). One at a time; the first list showing the
// world claims it, so two lists on one world don't both open a field.
@(private="file")
rename: struct {
    world:  ^World,
    handle: Entity_Handle,
    panel:  u32,        // the list panel drawing the field; 0 = not claimed yet
    focus:  bool,       // put the keyboard in the field on its first frame
    buf:    [128]u8,
}

// Starts renaming `w`'s active entity (F2, the right-click menu).
ui_entity_rename_begin :: proc(w: ^World) {
    e, ok := entity_get(w, w.active)
    if !ok do return
    rename = {world = w, handle = w.active, focus = true}
    copy(rename.buf[:len(rename.buf) - 1], sbuf_str(&e.name))
}

// The field replacing a row. Enter or clicking away keeps the name, Esc cancels. One undo step;
// names stay unique per world.
@(private="file")
rename_row :: proc(p: ^Entity_Panel, w: ^World, h: Entity_Handle) {
    rename.panel = p.id
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
    _, ok := entity_get(w, w.select_anchor)
    return ok
}


@(private="file")
ui_entity_inspector_body :: proc(p: ^Entity_Panel, w: ^World) {
    ui_world_unsaved_note(w)

    e, ok := entity_get(w, w.active)
    if !ok do return
    if n := selection_count(w); n > 1 do im.TextDisabled("%s", fmt.ctprintf(string(tr(.Inspector_Multi)), n))

    single := entity_count_blocks(string(im.GetClipboardText())) == 1
    im.BeginDisabled(!single)
    if im.Button(fmt.ctprintf("%s %s", ICON_PASTE, tr(.Btn_Paste_Over))) do ui_paste_over(w)
    im.EndDisabled()
    ui_panel_search_box(p, tr(.Inspector_Search))
    im.Separator()

    // The fields scroll under the header (buttons, search), which stays put.
    im.BeginChild("##fields")
    defer im.EndChild()

    // The rest of the selection: the inspector shows where they differ, and edits apply to them too.
    others := make([dynamic]rawptr, context.temp_allocator)
    for h in selection_handles(w) {
        if h == w.active do continue
        if o, found := entity_get(w, h); found do append(&others, o)
    }
    defaults: Entity
    entity_apply_defaults(&defaults)

    opts := DEFAULT_PARAM_UI_OPTIONS
    opts.headerless = true
    opts.filter     = strings.trim_space(string(cstring(&p.search[0])))
    opts.defaults   = &defaults
    opts.others     = others[:]
    before := e^
    ui_param_struct("entity", Entity, e^, opts)

    // Names stay unique per world. Checked once nothing is being edited — not per keystroke, which
    // would rename "car" to "car_1" mid-word while typing "car_12".
    if !im.IsAnyItemActive() do world_fix_duplicate_name(w, w.active)

    // Undo for inspector edits, detected after the fact (the reflection widgets don't report edits):
    // the first frame the entity changes opens one step holding its pre-edit state, and the step stays
    // open while a widget is held, so a whole drag or a typed name is one Ctrl+Z.
    if mem.compare_ptrs(&before, e, size_of(Entity)) != 0 {
        if !ui.inspector_editing {
            undo_push_edited(w, w.active, before)
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
ui_panel_search_box :: proc(p: ^Entity_Panel, hint: cstring) {
    im.SetNextItemWidth(-1)
    im.InputTextWithHint("##search", fmt.ctprintf("%s  %s", ICON_SEARCH, hint), cstring(&p.search[0]), len(p.search))
}

// Override: make every selected entity look/behave like the clipboard entity WITHOUT becoming it or
// moving — identity (name) and placement (transform) are always preserved. One undo step.
ui_paste_over :: proc(w: ^World) {
    clip := string(im.GetClipboardText())
    if entity_count_blocks(clip) != 1 || selection_count(w) == 0 do return
    undo_push(w)                                                // snapshot FIRST
    for h in selection_handles(w) {                             // every selected entity
        e := entity_get(w, h) or_continue
        entity_apply_text(e, clip, vmem.arena_allocator(&w.arena), {"identity", "placement"})
        entity_intern_keys(e)                                   // re-intern the pasted asset keys
    }
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
