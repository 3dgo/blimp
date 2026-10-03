package blimp

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import im "lib:odin-imgui"

// World Settings window: the [world] section of one world (World_Settings), opened from the gear
// button in that world's viewport toolbar. Reflection inspector, so a new settings field shows up
// with no UI code. Edits are one undo step per widget interaction and mark the world unsaved, like
// entity edits. Like every settings window but Bake, it shows the world the view shows: during play the
// play copy, whose edits go with it at Stop.
@(private="file")
settings_ui: Settings_Window

WORLD_SETTINGS_WINDOW_SIZE :: [2]f32{380, 220}   // first-open size (× display scale)

ui_world_settings_toggle   :: proc(w: ^World) { settings_window_toggle(&settings_ui, w) }
ui_world_settings_open_for :: proc(w: ^World) -> bool { return settings_window_open_for(&settings_ui, w) }
ui_world_settings_retarget :: proc(from, to: ^World) { settings_window_retarget(&settings_ui, from, to) }
ui_world_settings_forget   :: proc(w: ^World) { settings_window_forget(&settings_ui, w) }

// VS Code's command-line launcher ("code" for the stable build). It's a .cmd, which CreateProcess
// can't start directly, so it goes through cmd.
CODE_EDITOR :: "code-insiders"

// Opens the world's Lua script in VS Code, in a window on the whole project: an existing window on
// the project is reused, else a new one opens. The script path is project-relative, as is the cwd.
// A .lua built from a .luacn (codegen_luacn.odin) opens the .luacn: that's the one to edit.
world_settings_edit_script :: proc(w: ^World) {
    script := sbuf_str(&w.settings.script)
    if script == "" do return
    if luacn := fmt.tprintf("%scn", script); strings.has_suffix(script, ".lua") && os.exists(luacn) do script = luacn
    root, _ := os.get_working_directory(context.temp_allocator)
    if _, err := os.process_start({command = {"cmd", "/c", CODE_EDITOR, root, "-g", script}}); err != nil {
        log.errorf("Couldn't start %s for %s: %v", CODE_EDITOR, script, err)
    }
}

ui_draw_world_settings :: proc() {
    w := settings_ui.world
    if w == nil do return
    open := true
    s := app.display_scale
    im.SetNextWindowSize({WORLD_SETTINGS_WINDOW_SIZE.x * s, WORLD_SETTINGS_WINDOW_SIZE.y * s}, .FirstUseEver)
    if im.Begin(fmt.ctprintf("%s — %s###world_settings", tr(.Win_World_Settings), w.title), &open) {
        ui_world_unsaved_note(w)

        before := w.settings
        opts := DEFAULT_PARAM_UI_OPTIONS
        opts.headerless = true
        ui_param_struct("world", World_Settings, w.settings, opts)
        settings_window_track_edit(&settings_ui, before)
    }
    im.End()
    if !open do settings_ui.world = nil
}
