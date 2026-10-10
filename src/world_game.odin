package blimp

import "core:log"

// What the game carries from one level to the next: health, keys, which door the player came through.
// Lua holds no state (CLAUDE.md), and a level's entities go when the level does, so a script that wants
// something to outlive the level writes it here (Game.set_number / Game.set_string) and the next level's
// start reads it back.
//
// It lives on the play world and moves to the next level's play world on a level switch
// (world_play_switch), so its lifetime is one play session: Play starts it empty, Stop throws it away.
// Fixed slots of inline text, so it copies by value and needs no allocator. A key holds a number and a
// text side by side; each getter reads its own side, 0 / "" when the key was never set.
//
// Later a save game is this, written to a file.

MAX_GAME_VALUES :: 64
GAME_KEY_BYTES  :: 64   // Game_Value.key is an sbuf64

Game_Value :: struct {
    key:    sbuf64,
    number: f64,
    text:   sbuf256,
}

Game_State :: struct {
    values: [MAX_GAME_VALUES]Game_Value,
    count:  int,
}

game_number :: proc(g: ^Game_State, key: string) -> f64 {
    v, ok := game_find(g, key)
    return ok ? v.number : 0
}

game_text :: proc(g: ^Game_State, key: string) -> string {
    v, ok := game_find(g, key)
    return ok ? sbuf_str(&v.text) : ""
}

// False (logged) when the slots are full or the key is too long.
game_set_number :: proc(g: ^Game_State, key: string, value: f64) -> bool {
    v := game_slot(g, key) or_return
    v.number = value
    return true
}

game_set_text :: proc(g: ^Game_State, key: string, value: string) -> bool {
    v := game_slot(g, key) or_return
    sbuf_set(&v.text, value)
    return true
}

@(private="file")
game_find :: proc(g: ^Game_State, key: string) -> (^Game_Value, bool) {
    for &v in g.values[:g.count] do if sbuf_str(&v.key) == key do return &v, true
    return nil, false
}

// The key's slot, made if it's new.
@(private="file")
game_slot :: proc(g: ^Game_State, key: string) -> (^Game_Value, bool) {
    if v, ok := game_find(g, key); ok do return v, true
    if len(key) > GAME_KEY_BYTES {   // stored truncated, it would never match again
        log.errorf("Game state key '%s' is longer than %d bytes; not stored", key, GAME_KEY_BYTES)
        return nil, false
    }
    if g.count == MAX_GAME_VALUES {
        log.errorf("Game state is full (%d keys); '%s' not stored", MAX_GAME_VALUES, key)
        return nil, false
    }
    v := &g.values[g.count]
    g.count += 1
    v^ = {}
    sbuf_set(&v.key, key)
    return v, true
}
