package blimp

import "core:mem"
import im "lib:odin-imgui"

// The Game Settings window (Show menu): game.ini, settings that aren't one world's (game_settings.odin).
// Reflection inspector, like World Settings. Not undoable; the file is written once an edit ends.

GAME_SETTINGS_WINDOW_SIZE :: [2]f32{420, 160}   // first-open size (× display scale)

@(private="file") game_settings_edited: bool   // changed since the last write

ui_draw_game_settings :: proc() {
    if !ui.show_game_settings do return
    s := app.dispaly_scale
    im.SetNextWindowSize({GAME_SETTINGS_WINDOW_SIZE.x * s, GAME_SETTINGS_WINDOW_SIZE.y * s}, .FirstUseEver)
    if im.Begin(tr(.Win_Game_Settings), &ui.show_game_settings) {
        before := game_settings
        opts := DEFAULT_PARAM_UI_OPTIONS
        opts.headerless = true
        ui_param_struct("game", Game_Settings, game_settings, opts)
        if mem.compare_ptrs(&before, &game_settings, size_of(Game_Settings)) != 0 do game_settings_edited = true
        im.TextDisabled(GAME_SETTINGS_PATH)   // where it's written
    }
    im.End()
    if game_settings_edited && !im.IsAnyItemActive() {
        game_settings_save()
        game_settings_edited = false
    }
}
