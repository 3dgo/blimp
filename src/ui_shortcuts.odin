package blimp

import im "lib:odin-imgui"

ui_handle_shortcuts :: proc() {
    if ui.io.WantTextInput do return        // don't hijack keys while typing in a field
    if ui_unsaved_active() do return        // the unsaved-changes prompt is up: it has the keyboard
    ctrl  := ui.io.KeyCtrl
    shift := ui.io.KeyShift

    // One history across all worlds.
    if ctrl && im.IsKeyPressed(.Z) {
        if shift do redo()
        else     do undo()
    }

    // Copy and paste act on the active world (the viewport last focused), so copying from a kit
    // into a scene is: click the kit's car, Ctrl+C, click into the scene's viewport, Ctrl+V.
    if active_view != nil {
        // The actions are shared with the right-click menu (ui_context_menu.odin).
        w := active_view.world
        if ctrl && im.IsKeyPressed(.D, false) do ui_duplicate_selection(w)   // in place (Unity), one undo step
        if ctrl && im.IsKeyPressed(.C)        do ui_copy_selection(w)
        if ctrl && im.IsKeyPressed(.V)        do ui_paste_at(w, paste_target_point(editor_view(active_view)))   // at the cursor's raycast
        if ctrl && im.IsKeyPressed(.A, false) do ui_select_all(w)
    }

    if im.IsKeyPressed(.F3, false) do ui.show_stats = !ui.show_stats   // FPS + GPU time per pass

    // View shortcuts act on the viewport under the mouse, else the active one.
    target := active_view
    for v in views do if editor_view(v).hovered { target = v; break }
    if target == nil do return
    w := target.world
    target_ev := editor_view(target)
    dragging := target_ev.gizmo.drag != .None

    // Function keys, so Esc and the letter keys stay free for games. F5–F7 play mode, F10 frame step,
    // F8 game mode while playing (ui_game.odin),
    // F9 relaunch (app.odin), F12 RenderDoc's capture key.
    if im.IsKeyPressed(.F2, false)  do ui_entity_rename_begin(w)        // inline in the entity list
    if im.IsKeyPressed(.F5, false)  do ui_play(target)                  // and shows it as the game
    if im.IsKeyPressed(.F6, false)  do world_pause_toggle(w)
    if im.IsKeyPressed(.F7, false)  do world_stop(w)
    if im.IsKeyPressed(.F8, false)  do ui_game_enter(target)            // while playing: back to the game
    if im.IsKeyPressed(.F10, false) do world_step(w)                    // one frame, while paused
    if im.IsKeyPressed(.F11, false) do ui_maximize_toggle(target)

    if ctrl {
        if im.IsKeyPressed(.S, false) do world_save(w)   // a play world has no save path: nothing is saved from play
        return
    }
    if im.IsKeyPressed(.F, false) do editor_frame_selection(target_ev)
    // Esc deselects — unless it's closing a popup or cancelling a gizmo drag (the gizmo handles that).
    if im.IsKeyPressed(.Escape, false) && !im.IsPopupOpen("", im.PopupFlags_AnyPopup) && !dragging {
        selection_clear(w)
    }
    if im.IsKeyPressed(.Delete, false) && !dragging do ui_delete_selection(w)   // the whole selection, one undo step
    // Tool keys, Unity's layout (Q W E R, X = Global/Local, Z = pivot mode). Not while flying: RMB + W is "fly forward".
    if !im.IsMouseDown(.Right) {
        if im.IsKeyPressed(.Q, false) do ui.tool = .Select
        if im.IsKeyPressed(.W, false) do ui.tool = .Move
        if im.IsKeyPressed(.E, false) do ui.tool = .Rotate
        if im.IsKeyPressed(.R, false) do ui.tool = .Scale
        if im.IsKeyPressed(.G, false) do ui_game_view_toggle(target)   // Unreal's game view
        if im.IsKeyPressed(.X, false) do ui.space = ui.space == .Global ? .Local : .Global   // Unity's key for Global/Local
        if im.IsKeyPressed(.Z, false) do ui.pivot = ui.pivot == .Selection_Center ? .Individual_Pivots : .Selection_Center   // Unity's key for Pivot/Center
    }
}
