package blimp

import "core:log"
import "core:os"
import im "lib:odin-imgui"

// Game mode: one view fills the whole window as the game, rendered through its world's camera entity
// (world_game_camera), and the editor isn't drawn at all, so none of its windows, input or shortcuts
// run. Play (F5, the toolbar Play) enters it on that view; F8 switches between it and the editor while
// playing (the game keeps running); Stop leaves it. A release build plays Game_Settings.start_level in
// it at startup and never leaves it: there's no editor to switch to.

// Shows `v` as the game. `v` must be showing a play world.
ui_game_enter :: proc(v: ^Render_View) {
    if v.world.play_source == nil do return
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

// The whole frame's UI in game mode: the game view, plus what still has to work while it's up.
ui_draw_game :: proc() {
    // The view fills the main window, no decoration. The editor's windows aren't submitted, so their
    // docking and layout stay as they were for when the editor comes back.
    v := ui.game
    mv := im.GetMainViewport()
    im.SetNextWindowPos(mv.Pos)
    im.SetNextWindowSize(mv.Size)
    im.SetNextWindowViewport(mv.ID_)
    im.PushStyleVarImVec2(im.StyleVar.WindowPadding, {0, 0})
    im.PushStyleVar(im.StyleVar.WindowBorderSize, 0)
    if im.Begin("###game", nil, im.WindowFlags_NoDecoration + {.NoDocking, .NoMove, .NoSavedSettings, .NoScrollWithMouse}) {
        ui_view_image(v)
    }
    im.End()
    im.PopStyleVar(2)

    ui_draw_unsaved_prompt()   // closing the window while playing still asks about the level
    if ui.show_stats do ui_draw_stats()
    ui_draw_log_overlay()
    ui_game_shortcuts()   // last: F8 leaves game mode (ui.game = nil)
}

// Only function keys, so the letters and Esc are the game's. F9 relaunch is in app.odin.
@(private="file")
ui_game_shortcuts :: proc() {
    if ui_unsaved_active() do return
    if im.IsKeyPressed(.F3, false) do ui.show_stats = !ui.show_stats
    when ODIN_DEBUG {
        w := ui.game.world
        if im.IsKeyPressed(.F6, false)  do world_pause_toggle(w)
        if im.IsKeyPressed(.F7, false)  do app_stop(w)   // ui_update leaves game mode next frame
        if im.IsKeyPressed(.F8, false)  do ui_game_leave()
        if im.IsKeyPressed(.F10, false) do world_step(w)
    }
}
