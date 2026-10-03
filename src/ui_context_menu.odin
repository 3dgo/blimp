package blimp

import "core:fmt"
import "core:strings"
import hm "core:container/handle_map"
import im "lib:odin-imgui"

// Entity edit actions, shared by the keyboard shortcuts (ui_handle_shortcuts) and the right-click
// menu, plus that menu. Each action that edits calls undo_push first.

// Copies the whole selection to the OS clipboard, one [entity] block each.
ui_copy_selection :: proc(w: ^World) {
    b := strings.builder_make(context.temp_allocator)
    for h in selection_handles(w) {
        e := entity_get(w, h) or_continue
        strings.write_string(&b, entity_to_text(e, context.temp_allocator))
        strings.write_byte(&b, '\n')
    }
    if strings.builder_len(b) > 0 do im.SetClipboardText(strings.to_cstring(&b))
}

// Pastes the clipboard as new entities at `pos`, and selects what it made. One entity: the clipboard
// transform is ignored (rotation/scale default, position = pos). Several: they keep their layout —
// positions, rotations and scales as copied — moved as a group so their centre lands on pos.
ui_paste_at :: proc(w: ^World, pos: vec3) {
    clip := string(im.GetClipboardText())
    blocks := entity_count_blocks(clip)
    if blocks == 0 do return
    undo_push(w)
    handles := make([dynamic]Entity_Handle, context.temp_allocator)
    skip := blocks == 1 ? []string{"placement"} : []string{}
    scene_load_from_text(w, clip, &handles, skip)
    centre: vec3
    if blocks > 1 {
        for h in handles do if e, ok := entity_get(w, h); ok do centre += e.position
        centre /= f32(max(len(handles), 1))
    }
    selection_clear(w)
    for h in handles {
        e := entity_get(w, h) or_continue
        e.position = blocks == 1 ? pos : pos + (e.position - centre)
        selection_set(w, h, true)
    }
}

// Copies the selection in place and selects the copies (Unity's Ctrl+D).
ui_duplicate_selection :: proc(w: ^World) {
    if selection_count(w) == 0 do return
    undo_push(w)
    selection_duplicate(w)
}

ui_delete_selection :: proc(w: ^World) {
    if selection_count(w) == 0 do return
    undo_push(w)
    for h in selection_handles(w) do selection_remove_entity(w, h)
}

ui_select_all :: proc(w: ^World) {
    it := hm.iterator_make(&w.entities)
    for _, h in hm.iterate(&it) do selection_set(w, h, true)
}

// Sets the Hidden flag on the selection. Hidden entities aren't drawn or pickable; they stay selected
// and listed, so the entity list (or Unhide All) brings them back.
ui_hide_selection :: proc(w: ^World) {
    if selection_count(w) == 0 do return
    undo_push(w)
    for h in selection_handles(w) {
        e := entity_get(w, h) or_continue
        e.basic_flags += {.Hidden}
    }
}

ui_unhide_all :: proc(w: ^World) {
    if !world_any_hidden(w) do return
    undo_push(w)
    it := hm.iterator_make(&w.entities)
    for e, _ in hm.iterate(&it) do e.basic_flags -= {.Hidden}
}

@(private="file")
world_any_hidden :: proc(w: ^World) -> bool {
    it := hm.iterator_make(&w.entities)
    for e, _ in hm.iterate(&it) do if .Hidden in e.basic_flags do return true
    return false
}

/* ------------------------------- Context menu ------------------------------- */
// Opened by a right-click in a viewport (a click, not a fly drag) or in an entity list. The window
// that opens it also draws it, since a popup lives in its window's ID scope. One menu is open at a
// time, so its target is file state, captured when it opens: the mouse is over the menu by the time
// an item is clicked, so the paste point can't be read then.
@(private="file")
context_menu: struct {
    world:    ^World,
    view:     ^Render_View,   // for Frame Selection; nil when no view shows the world
    paste_at: vec3,
}

CONTEXT_MENU_ID :: "##entity_context"

// Opens the menu in the current window, acting on `w`'s selection and pasting at `paste_at`.
ui_context_menu_open :: proc(w: ^World, view: ^Render_View, paste_at: vec3) {
    context_menu = {w, view, paste_at}
    world_activate(w)
    im.OpenPopup(CONTEXT_MENU_ID)
}

// A world or view is closing: drop a menu aimed at it.
ui_context_menu_forget :: proc(w: ^World, v: ^Render_View) {
    if context_menu.world == w do context_menu = {}
    if v != nil && context_menu.view == v do context_menu.view = nil
}

// Draws the menu if this window opened it.
ui_context_menu :: proc() {
    if !im.BeginPopup(CONTEXT_MENU_ID) do return
    defer im.EndPopup()
    w := context_menu.world
    if w == nil {
        im.CloseCurrentPopup()
        return
    }

    n := selection_count(w)
    blocks := entity_count_blocks(string(im.GetClipboardText()))
    item :: proc(icon: string, label: Loc_ID, shortcut: cstring, enabled: bool) -> bool {
        return im.MenuItem(fmt.ctprintf("%s  %s", icon, tr(label)), shortcut, false, enabled)
    }

    if item(ICON_COPY,       .Ctx_Copy,       "Ctrl+C", n > 0)                do ui_copy_selection(w)
    if item(ICON_PASTE,      .Ctx_Paste,      "Ctrl+V", blocks > 0)           do ui_paste_at(w, context_menu.paste_at)
    if item(ICON_PASTE_OVER, .Btn_Paste_Over, nil,      blocks == 1 && n > 0) do ui_paste_over(w)
    if item(ICON_DUPLICATE,  .Ctx_Duplicate,  "Ctrl+D", n > 0)                do ui_duplicate_selection(w)
    if item(ICON_RENAME,     .Ctx_Rename,     "F2",     n > 0)                do ui_entity_rename_begin(w)
    if item(ICON_DELETE,     .Ctx_Delete,     "Delete", n > 0)                do ui_delete_selection(w)
    im.Separator()
    if item(ICON_SELECT_ALL, .Ctx_Select_All, "Ctrl+A", hm.len(w.entities) > 0) do ui_select_all(w)
    if item(ICON_DESELECT,   .Ctx_Deselect,   "Esc",    n > 0)                  do selection_clear(w)
    if item(ICON_FRAME,      .Ctx_Frame,      "F",      n > 0 && context_menu.view != nil) {
        editor_frame_selection(editor_view(context_menu.view))
    }
    im.Separator()
    if item(ICON_HIDE,       .Ctx_Hide,       nil,      n > 0)               do ui_hide_selection(w)
    if item(ICON_SHOW,       .Ctx_Unhide_All, nil,      world_any_hidden(w)) do ui_unhide_all(w)
}

// The first view showing `w`, or nil.
ui_first_view_of :: proc(w: ^World) -> ^Render_View {
    for v in views do if v.world == w do return v
    return nil
}

// Override: make every selected entity look/behave like the clipboard entity WITHOUT becoming it or
// moving — identity (name) and placement (transform) are always preserved. One undo step.
ui_paste_over :: proc(w: ^World) {
    clip := string(im.GetClipboardText())
    if entity_count_blocks(clip) != 1 || selection_count(w) == 0 do return
    undo_push(w)                                                // snapshot FIRST
    for h in selection_handles(w) {                             // every selected entity
        e := entity_get(w, h) or_continue
        entity_apply_text(e, clip, {"identity", "placement"})
        entity_intern_keys(e)                                   // re-intern the pasted asset keys
    }
}
