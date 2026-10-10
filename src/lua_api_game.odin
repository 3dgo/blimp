package blimp

// The script API's Game table (游戏): what the game carries from one level to the next (world_game.odin), on
// the play world whose script is running. Lua holds no state, so this is where a value goes when it must outlive
// the level: health, keys, the entry the next level puts the player at. Play starts it empty; Stop clears it.
// A key holds a number or a string, whichever was set last. A dotted key ("玩家.生命值") shows as a group in
// the Game Globals window and blimpctl's `globals`.

// The number stored under `key`; 0 if it was never set or holds a string.
// zh: `键` 下存的数字；没设过或存的是文本时返回 0。
@(lua=get_number, table=Game, lua_zh="取数")
game_get_number_lua :: proc(key: string) -> f64 {
    w := lua_world() or_else nil
    return w != nil ? game_number(&w.game, key) : 0
}

// Stores a number under `key` for the rest of the game, across level switches (World.switch_level).
// zh: 把数字存在 `键` 下，切换关卡（世界.切换关卡）后还在，直到这次运行结束。
@(lua=set_number, table=Game, lua_zh="设数")
game_set_number_lua :: proc(key: string, value: f64) {
    if w, ok := lua_world(); ok do game_set_number(&w.game, key, value)
}

// The string stored under `key`; "" if it was never set or holds a number.
// zh: `键` 下存的文本；没设过或存的是数字时返回 ""。
@(lua=get_string, table=Game, lua_zh="取文本")
game_get_string_lua :: proc(key: string) -> string {
    w := lua_world() or_else nil
    return w != nil ? game_string(&w.game, key) : ""
}

// Stores a string (up to 256 bytes) under `key` for the rest of the game, across level switches.
// zh: 把文本（最多 256 字节）存在 `键` 下，切换关卡后还在，直到这次运行结束。
@(lua=set_string, table=Game, lua_zh="设文本")
game_set_string_lua :: proc(key: string, value: string) {
    if w, ok := lua_world(); ok do game_set_string(&w.game, key, value)
}
