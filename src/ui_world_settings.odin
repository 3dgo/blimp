package blimp

import "core:fmt"
import "core:mem"
import im "lib:odin-imgui"

// World Settings window: the [world] section of one world (World_Settings), opened from the gear
// button in that world's viewport toolbar. Reflection inspector, so a new settings field shows up
// with no UI code. Edits are one undo step per widget interaction and mark the world unsaved, like
// entity edits.
@(private="file")
settings_ui: struct {
    world:   ^World,   // whose settings are shown; nil = window closed
    editing: bool,     // an edit's undo step is open (closed once no widget is active)
}

WORLD_SETTINGS_WINDOW_SIZE :: [2]f32{380, 220}   // first-open size (× display scale)

ui_world_settings_toggle :: proc(w: ^World) {
    settings_ui.world = settings_ui.world == w ? nil : w
}

ui_world_settings_open_for :: proc(w: ^World) -> bool { return settings_ui.world == w }

// The world's views switched to `to` (Play / Stop): show that one's settings instead.
ui_world_settings_retarget :: proc(from, to: ^World) {
    if settings_ui.world == from do settings_ui.world = to
}

// The world is closing.
ui_world_settings_forget :: proc(w: ^World) {
    if settings_ui.world == w do settings_ui = {}
}

ui_draw_world_settings :: proc() {
    w := settings_ui.world
    if w == nil do return
    open := true
    s := app.dispaly_scale
    im.SetNextWindowSize({WORLD_SETTINGS_WINDOW_SIZE.x * s, WORLD_SETTINGS_WINDOW_SIZE.y * s}, .FirstUseEver)
    if im.Begin(fmt.ctprintf("%s — %s###world_settings", tr(.Win_World_Settings), w.title), &open) {
        ui_world_unsaved_note(w)

        before := w.settings
        opts := DEFAULT_PARAM_UI_OPTIONS
        opts.headerless = true
        ui_param_struct("world", World_Settings, w.settings, opts)

        // Undo, detected after the fact (as in the entity inspector): the first changed frame opens a
        // step holding the pre-edit settings; it stays open while a widget is held.
        if mem.compare_ptrs(&before, &w.settings, size_of(World_Settings)) != 0 && !settings_ui.editing {
            undo_push_settings_edited(w, before)
            settings_ui.editing = true
        }
        if !im.IsAnyItemActive() do settings_ui.editing = false
    }
    im.End()
    if !open do settings_ui.world = nil
}
