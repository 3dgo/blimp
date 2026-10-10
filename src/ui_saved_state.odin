package blimp

import "core:fmt"
import "core:reflect"
import "core:strings"
import im "lib:odin-imgui"

// Editor UI state that outlives a run, saved in imgui.ini beside the layout as a [Blimp][Editor] entry
// (through an ImGui settings handler): the UI language and which windows are open, so a relaunch
// reopens them where they were docked. Only the project-wide windows: world windows, their views and
// the entity lists / inspectors belong to a world, so they aren't reopened. The values in ui_init and
// loc_lang's initializer are the defaults when the entry is missing.

@(private="file")
Saved_Window :: struct {
    key:  string,   // the ini key; keep it when renaming the flag, or saved layouts lose the window
    show: ^bool,
}

@(private="file")
SAVED_WINDOW_COUNT :: 7

@(private="file")
saved_windows :: proc() -> [SAVED_WINDOW_COUNT]Saved_Window {
    return {
        {"worlds",        &ui.show_worlds},
        {"schema_editor", &ui.show_schema_editor},
        {"game_settings", &ui.show_game_settings},
        {"game_globals",  &ui.show_game_globals},
        {"resources",     &ui.show_resources},
        {"shadow_maps",   &ui.show_shadow_maps},
        {"stats",         &ui.show_stats},
    }
}

// As last written or read; a difference marks the ini dirty.
@(private="file") saved_windows_last: [SAVED_WINDOW_COUNT]bool
@(private="file") saved_lang_last: Lang

// Registers the handler. Call after CreateContext and before the first NewFrame (which reads the ini).
ui_saved_state_init :: proc() {
    saved_lang_last = loc_lang
    h := im.SettingsHandler{
        TypeName   = "Blimp",
        TypeHash   = im.cImHashStr("Blimp"),
        ReadOpenFn = saved_state_read_open,
        ReadLineFn = saved_state_read_line,
        WriteAllFn = saved_state_write_all,
    }
    im.AddSettingsHandler(&h)   // ImGui keeps a copy
}

// Once per frame: ImGui only saves when something it tracks changed, so a window opened or closed
// (menu or ×) or a language switch marks the ini dirty here. It's written at ImGui's save rate and on exit.
ui_saved_state_update :: proc() {
    for w, i in saved_windows() {
        if w.show^ == saved_windows_last[i] do continue
        saved_windows_last[i] = w.show^
        im.MarkIniSettingsDirty()
    }
    if loc_lang != saved_lang_last {
        saved_lang_last = loc_lang
        im.MarkIniSettingsDirty()
    }
}

@(private="file")
saved_state_read_open :: proc "c" (ctx: ^im.Context, handler: ^im.SettingsHandler, name: cstring) -> rawptr {
    return name == "Editor" ? rawptr(uintptr(1)) : nil   // non-nil: read this entry's lines
}

@(private="file")
saved_state_read_line :: proc "c" (ctx: ^im.Context, handler: ^im.SettingsHandler, entry: rawptr, line: cstring) {
    context = app.g_context
    k, _, v := strings.partition(string(line), "=")
    key, val := strings.trim_space(k), strings.trim_space(v)
    if key == "language" {
        if lang, ok := reflect.enum_from_name(Lang, val); ok do loc_lang, saved_lang_last = lang, lang
        return
    }
    for w, i in saved_windows() do if w.key == key {
        w.show^ = val == "1"
        saved_windows_last[i] = w.show^
    }
}

@(private="file")
saved_state_write_all :: proc "c" (ctx: ^im.Context, handler: ^im.SettingsHandler, out: ^im.TextBuffer) {
    context = app.g_context
    im.TextBuffer_append(out, "[Blimp][Editor]\n")
    im.TextBuffer_append(out, fmt.ctprintf("language=%v\n", loc_lang))
    for w in saved_windows() do im.TextBuffer_append(out, fmt.ctprintf("%s=%d\n", w.key, w.show^ ? 1 : 0))
    im.TextBuffer_append(out, "\n")
}
