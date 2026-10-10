package blimp

import "core:log"
import "core:os"
import im "lib:odin-imgui"

// Game mode: the view Play ran in shows the game, through its world's camera entity (world_game_camera), with none
// of the editor's tools (no icons, gizmo, selection or camera navigation), and the game takes the keyboard and
// mouse while that view's window has the focus. Every other window stays as it is; one level plays at a time
// (app_play), so there's at most this one view. Play (F5, the toolbar Play) enters it on that view; F8 switches
// it between the game's camera and the editor's while playing (the game keeps running); Stop leaves it. A release
// build plays Game_Settings.start_level at startup with that view filling the whole window, and never leaves it.

// Shows `v` as the game. `v` must be showing a play world.
ui_game_enter :: proc(v: ^Render_View) {
    if v.world.play_source == nil do return
    if ui.game != nil do ui.game.camera_entity = {}   // another view of the same play world: back to its editor camera
    v.camera_entity = world_game_camera(v.world)
    if v.camera_entity == {} do log.warnf("Game mode: no enabled camera entity in '%s', showing the editor camera", v.world.title)
    ui.game = v
}

// Back to the editor, which shows the view through its editor camera again.
ui_game_leave :: proc() {
    when !ODIN_DEBUG do return
    if ui.game == nil do return
    ui.game.camera_entity = {}
    ui.game = nil
}

// Whether the game gets the keyboard and mouse this frame (input_update): in the editor, while the game view's
// window has the focus (as of last frame's UI); a release build is only the game.
ui_game_has_input :: proc() -> bool {
    when ODIN_DEBUG {
        return ui.game != nil && ui.game_focus
    } else {
        return ui.game != nil
    }
}

// Play from the editor: run `v`'s level and show it as the game in `v`.
ui_play :: proc(v: ^Render_View) {
    app_play(v.world)   // `v` now shows the play world
    ui_game_enter(v)
}

// Startup: open Game Settings' start level. A release build plays it as the game straight away.
ui_game_start :: proc() {
    path := sbuf_str(&game_settings.start_level)
    if path == "" do return
    if !os.exists(path) { log.errorf("Start level '%s' not found (Game Settings)", path); return }
    w := app_open_scene(path)
    when ODIN_DEBUG do _ = w
    else {
        p := app_play(w)
        for v in views do if v.world == p { ui_game_enter(v); break }
    }
}

// A release build's whole frame UI: the game view fills the main window, no decoration, with what still has to
// work over it. (In the editor the game view is an ordinary view window: ui_draw_view.)
ui_draw_game :: proc() {
    v := ui.game
    mv := im.GetMainViewport()
    im.SetNextWindowPos(mv.Pos)
    im.SetNextWindowSize(mv.Size)
    im.SetNextWindowViewport(mv.ID_)
    im.PushStyleVarImVec2(im.StyleVar.WindowPadding, {0, 0})
    im.PushStyleVar(im.StyleVar.WindowBorderSize, 0)
    if im.Begin("###game", nil, im.WindowFlags_NoDecoration + {.NoDocking, .NoMove, .NoSavedSettings, .NoScrollWithMouse}) {
        ui_view_image(v)
        ui_view_game_ui(v, im.GetItemRectMin(), im.GetItemRectMax())   // the script's screen UI (World.ui)
    }
    im.End()
    im.PopStyleVar(2)

    ui_draw_unsaved_prompt()   // if a close is waiting on it
    if ui.show_stats do ui_draw_stats()
    ui_draw_log_overlay()
    ui_game_shortcuts()
}

// While the game has the keyboard, only function keys, so the letters and Esc are the game's. F9 relaunch is
// in app.odin.
ui_game_shortcuts :: proc() {
    if ui_unsaved_active() do return
    if im.IsKeyPressed(.F3, false) do ui.show_stats = !ui.show_stats
    when ODIN_DEBUG {
        w := ui.game.world
        if im.IsKeyPressed(.F6, false)  do world_pause_toggle(w)
        if im.IsKeyPressed(.F7, false)  do app_stop(w)   // ui_update leaves game mode next frame
        if im.IsKeyPressed(.F8, false)  do ui_game_leave()
        if im.IsKeyPressed(.F10, false) do world_step(w)
        if im.IsKeyPressed(.F11, false) do ui_maximize_toggle(ui.game)
    }
}
