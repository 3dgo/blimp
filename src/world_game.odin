package blimp

import "base:runtime"
import "core:log"
import "core:slice"

// What the game carries from one level to the next: health, keys, which door the player came through.
// Lua holds no state (CLAUDE.md), and a level's entities go when the level does, so a script that wants
// something to outlive the level writes it here (Game.set_number / Game.set_string) and the next level's
// start reads it back. The Game Globals window and blimpctl's `globals` show and edit it while the game runs.
//
// It lives on the play world and moves to the next level's play world on a level switch
// (world_play_switch), so its lifetime is one play session: Play starts it empty, Stop throws it away.
// Fixed slots of inline text, so it copies by value and needs no allocator. A key holds a number or a
// string, whichever was set last; a getter of the other kind reads 0 / "", as for a key never set.
// A dotted key is a path: "玩家.生命值" is 生命值 in a 玩家 group, wherever the keys are listed.
//
// Later a save game is this, written to a file.

MAX_GAME_VALUES :: 64
GAME_KEY_BYTES  :: 64   // Game_Value.key is an sbuf64

Game_Value_Kind :: enum u8 { Number, String }

Game_Value :: struct {
    key:    sbuf64,
    kind:   Game_Value_Kind,
    number: f64,
    str:    sbuf256,
}

Game_State :: struct {
    values: [MAX_GAME_VALUES]Game_Value,
    count:  int,
}

game_number :: proc(g: ^Game_State, key: string) -> f64 {
    v, ok := game_find(g, key)
    return ok && v.kind == .Number ? v.number : 0
}

game_string :: proc(g: ^Game_State, key: string) -> string {
    v, ok := game_find(g, key)
    return ok && v.kind == .String ? sbuf_str(&v.str) : ""
}

// False (logged) when the slots are full or the key is too long.
game_set_number :: proc(g: ^Game_State, key: string, value: f64) -> bool {
    v := game_slot(g, key) or_return
    v^ = {key = v.key, kind = .Number, number = value}
    return true
}

game_set_string :: proc(g: ^Game_State, key: string, value: string) -> bool {
    v := game_slot(g, key) or_return
    v^ = {key = v.key, kind = .String}
    sbuf_set(&v.str, value)
    return true
}

game_find :: proc(g: ^Game_State, key: string) -> (^Game_Value, bool) {
    for &v in g.values[:g.count] do if sbuf_str(&v.key) == key do return &v, true
    return nil, false
}

// The values in path order: '.' sorts before every other byte, so a group's keys stay together
// ("a", "a.b", "a.c", "a-c"). Pointers into `g`, for listing it this frame.
game_sorted :: proc(g: ^Game_State, allocator: runtime.Allocator) -> []^Game_Value {
    out := make([]^Game_Value, g.count, allocator)
    for &v, i in g.values[:g.count] do out[i] = &v
    slice.sort_by(out, proc(a, b: ^Game_Value) -> bool {
        x, y := sbuf_str(&a.key), sbuf_str(&b.key)
        for i in 0 ..< min(len(x), len(y)) {
            if x[i] == y[i] do continue
            if x[i] == '.' do return true
            if y[i] == '.' do return false
            return x[i] < y[i]
        }
        return len(x) < len(y)
    })
    return out
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
