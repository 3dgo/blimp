package blimp

import "core:log"
import "core:os"
import "core:strings"

// Game Settings: the project's settings that belong to the game rather than to one world, in
// game.ini at the project root (a [game] section, the same key = value codec as a scene's [world]).
// Read once at init. Edited in the Game Settings window (ui_game.odin), which writes the
// file after each edit. Only fields something reads; adding one is one line.
Game_Settings :: struct {
    start_level: sbuf256 `loc:Game_Start_Level`,   // scene opened at startup, and played as the game in a release build
}

GAME_SETTINGS_PATH :: "game.ini"

game_settings: Game_Settings

game_settings_load :: proc() {
    data, err := os.read_entire_file(GAME_SETTINGS_PATH, context.temp_allocator)
    if err != nil do return   // no file yet: the defaults
    ini_read_section(string(data), "game", game_settings)
}

game_settings_save :: proc() {
    b: strings.Builder
    strings.builder_init(&b, context.temp_allocator)
    strings.write_string(&b, "[game]\n")
    serialize_struct(&b, game_settings)
    if err := os.write_entire_file(GAME_SETTINGS_PATH, b.buf[:]); err != nil {
        log.errorf("Failed to write '%v': %v", GAME_SETTINGS_PATH, err)
    }
}
