package blimp

import "core:fmt"
import "core:log"
import "core:os"
import im "lib:odin-imgui"

// Unsaved-changes guard. Closing a dirty scene world (its last view's window, or Close in the Worlds
// window), or quitting or restarting (F9) the engine with any dirty world, asks first: Save / Don't Save /
// Cancel. Requests come in through ui_request_close_world / ui_request_close_view / ui_request_exit; the
// modal is drawn by ui_draw_unsaved_prompt once per frame, at top level.
Unsaved_Kind :: enum u8 { None, Close_World, Quit, Restart }

@(private="file")
Unsaved_Prompt :: struct {
    kind:  Unsaved_Kind,
    world: ^World,   // Close_World: the world being closed
}
@(private="file")
unsaved: Unsaved_Prompt

@(private="file") UNSAVED_POPUP :: "###unsaved_changes"

// Asks about the level, not a play copy (world_level): closing a playing world closes its level.
ui_request_close_world :: proc(w: ^World) {
    level := world_level(w)
    if world_dirty(level) do unsaved = {kind = .Close_World, world = level}
    else                  do world_request_close(level)
}

// A view's window was closed. Closing the last view closes its world, so that's when to ask.
ui_request_close_view :: proc(v: ^Render_View) {
    others := 0
    for o in views do if o != v && o.world == v.world do others += 1
    if level := world_level(v.world); others == 0 && world_dirty(level) {
        editor_view(v).window_open = true   // keep the window until the user decides
        unsaved = {kind = .Close_World, world = level}
        return
    }
    view_request_close(v)
}

// The engine is quitting (.Quit: its window closed) or relaunching (.Restart: F9, app.odin). True when it
// can go right away (nothing unsaved); otherwise the prompt opens and goes ahead if the user says so.
ui_request_exit :: proc(kind: Unsaved_Kind) -> bool {
    for w in worlds do if world_dirty(w) {
        unsaved = {kind = kind}
        return false
    }
    return true
}

// The prompt is up: editing shortcuts (undo, delete, …) wait, so the answer is about what's on screen.
ui_unsaved_active :: proc() -> bool { return unsaved.kind != .None }

// A world is closing for another reason (e.g. remote control): drop a prompt that's about it.
ui_unsaved_forget_world :: proc(w: ^World) {
    if unsaved.world == w do unsaved = {}
}

ui_draw_unsaved_prompt :: proc() {
    if unsaved.kind == .None do return
    // The reason can go away while the prompt is up (e.g. saved through blimpctl): then there's
    // nothing to decide, so carry out the close / quit that was asked for.
    still_dirty := false
    switch unsaved.kind {
    case .None:
    case .Close_World: still_dirty = world_dirty(unsaved.world)
    case .Quit, .Restart: for w in worlds do if world_dirty(w) do still_dirty = true
    }
    if !still_dirty && !im.IsPopupOpen(UNSAVED_POPUP) {
        unsaved_proceed()
        unsaved = {}
        return
    }
    if !im.IsPopupOpen(UNSAVED_POPUP) do im.OpenPopup(UNSAVED_POPUP)

    mv := im.GetMainViewport()
    im.SetNextWindowPos(mv.Pos + mv.Size * 0.5, .Appearing, {0.5, 0.5})
    if !im.BeginPopupModal(fmt.ctprintf("%s%s", tr(.Unsaved_Title), UNSAVED_POPUP), nil, {.AlwaysAutoResize, .NoSavedSettings}) do return
    if !still_dirty {   // already open: close it from inside, then carry on
        unsaved_proceed()
        unsaved = {}
        im.CloseCurrentPopup()
        im.EndPopup()
        return
    }

    switch unsaved.kind {
    case .None:
    case .Close_World:
        im.TextUnformatted(fmt.ctprintf("%s %s", unsaved.world.title, tr(.Unsaved_World_Msg)))
    case .Quit, .Restart:
        im.TextUnformatted(tr(.Unsaved_Quit_Msg))
        for w in worlds do if world_dirty(w) do im.BulletText("%s", fmt.ctprintf("%s", w.title))
    }
    im.Spacing()
    im.Separator()

    done := false
    if im.Button(unsaved.kind != .Close_World ? tr(.Btn_Save_All) : tr(.Btn_Save_Changes)) {
        // Go ahead only if every save worked; a failed write leaves the prompt up (see the log).
        saved := true
        if unsaved.kind == .Close_World do saved = world_save(unsaved.world)
        else do for w in worlds do if world_dirty(w) do saved = world_save(w) && saved
        if saved { unsaved_proceed(); done = true }
    }
    im.SameLine()
    if im.Button(tr(.Btn_Dont_Save)) { unsaved_proceed(); done = true }
    im.SameLine()
    if im.Button(tr(.Btn_Cancel)) || im.IsKeyPressed(.Escape, false) do done = true

    if done {
        unsaved = {}
        im.CloseCurrentPopup()
    }
    im.EndPopup()
}

@(private="file")
unsaved_proceed :: proc() {
    switch unsaved.kind {
    case .None:
    case .Close_World: world_request_close(unsaved.world)
    case .Quit:        app.quit_requested = true
    case .Restart:
        log.info("Restarting after the unsaved-changes prompt")
        app_spawn_self(os.args[1:])
        app.quit_requested = true
    }
}
