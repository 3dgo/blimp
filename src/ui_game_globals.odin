package blimp

import "core:fmt"
import "core:strings"
import im "lib:odin-imgui"

// The Game Globals window (Show menu): the game state (world_game.odin) of the active world's play world, what
// its scripts stored with Game.set_number / set_string, editable while the game runs. A dotted key is a path:
// "玩家.生命值" is a 生命值 row in a 玩家 group. Not undoable: it's runtime state, gone at Stop.

GAME_GLOBALS_WINDOW_SIZE :: [2]f32{360, 320}   // first-open size (× display scale)

ui_draw_game_globals :: proc() {
    if !ui.show_game_globals do return
    s := app.display_scale
    im.SetNextWindowSize({GAME_GLOBALS_WINDOW_SIZE.x * s, GAME_GLOBALS_WINDOW_SIZE.y * s}, .FirstUseEver)
    if im.Begin(tr(.Win_Game_Globals), &ui.show_game_globals) {
        w := active_world()
        if w != nil do w = world_level(w).play_world
        if w == nil {
            im.TextWrapped("%s", tr(.Game_Globals_Not_Playing))
        } else {
            ui_game_globals_tree(&w.game)
            if w.game.count == 0 do im.TextWrapped("%s", tr(.Game_Globals_Empty))
            else do im.TextDisabled("%s", fmt.ctprintf(string(tr(.Game_Globals_Count)), w.game.count, MAX_GAME_VALUES))
        }
    }
    im.End()
}

// The clock, then every key in path order, each group opened (ui_param_group_begin) where its first key comes. A
// row's label is the last part of its key; hovering it shows the whole key, as Lua and blimpctl name it.
@(private="file")
ui_game_globals_tree :: proc(g: ^Game_State) {
    values := game_sorted(g, context.temp_allocator)

    // One input column for every card, from the widest row label.
    widest := im.CalcTextSize(tr(.Game_Globals_Time)).x
    for v in values {
        key := sbuf_str(&v.key)
        widest = max(widest, im.CalcTextSize(fmt.ctprintf("%s", key[strings.last_index_byte(key, '.') + 1:])).x)
    }
    opts := DEFAULT_PARAM_UI_OPTIONS
    opts.label_w = ui_label_column_at(widest)

    // Setting it jumps the world: every level computes its state from it on the next tick.
    ui_param_label(string(tr(.Game_Globals_Time)), opts)
    ui_item_tooltip("World.time()")
    im.InputDouble("##game_time", &g.time, 0, 0, "%.2f")
    if g.time < 0 do g.time = 0

    // The groups the current key is inside; each is open only if it and every group around it are.
    Group :: struct { name: string, open: bool }
    groups := make([dynamic]Group, context.temp_allocator)
    for v in values {
        key := sbuf_str(&v.key)
        parts := strings.split(key, ".", context.temp_allocator)
        path := parts[:len(parts) - 1]

        same := 0
        for same < len(groups) && same < len(path) && groups[same].name == path[same] do same += 1
        for len(groups) > same do if pop(&groups).open do ui_param_group_end()
        for name, i in path[same:] {
            outer_open := len(groups) == 0 || groups[len(groups) - 1].open
            id := strings.join(parts[:same + i + 1], ".", context.temp_allocator)
            append(&groups, Group{name, outer_open && ui_param_group_begin(name, id, open = true)})
        }
        if len(groups) > 0 && !groups[len(groups) - 1].open do continue

        im.PushID(fmt.ctprintf("%s", key))
        ui_param_label(parts[len(parts) - 1], opts)
        ui_item_tooltip(key)
        switch v.kind {
        case .Number: im.InputDouble("##value", &v.number, 0, 0, "%g")
        case .String:   // as ui_param_sbuf, under this row's label
            buf: [cap(sbuf256{}) + 1]u8
            copy(buf[:], sbuf_str(&v.str))
            if im.InputText("##value", cstring(&buf[0]), len(buf)) do sbuf_set(&v.str, string(cstring(&buf[0])))
        }
        im.PopID()
    }
    for len(groups) > 0 do if pop(&groups).open do ui_param_group_end()
}
