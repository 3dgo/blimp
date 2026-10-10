package blimp

import "core:log"
import "core:path/filepath"
import "core:strings"
import hm "core:container/handle_map"

// Play mode: Play runs a copy of the world as the game, and Stop throws the copy away. The level is
// never touched while playing, so nothing the game does can leak into it: script changes, editor
// edits made during play, spawned or deleted entities, and physics, animation and audio state.
//
// - The play world is an ordinary World in `worlds`, built from the level (the same entities and
//   settings). It has no save_path, so it can't be saved, and its undo steps go when it closes.
// - Every view of the level switches to show the play world (the same windows, like Unity), and back
//   on Stop.
// - World scripts run only in play worlds (lua_worlds_update): the script loads, and runs its start
//   hook, on the first frame of play.
//
// This file is the world-layer half: the copy and its clock. app_play / app_stop (app_lifecycle.odin)
// also start and stop physics, sound and the script, and retarget the editor.
//
// - A script can switch the play world to another level (World.switch_level → world_play_switch): the new
//   level loads from its file as a fresh play world in the old one's place, carrying the game state
//   (world_game.odin). It still points back at the edited level, so Stop returns there.
//
// level.play_world → the running copy; play_world.play_source → its level. Both nil when not playing.

// The world that's saved and edited: the level a play world was copied from, else w itself.
world_level :: proc(w: ^World) -> ^World {
    return w.play_source != nil ? w.play_source : w
}

world_playing :: proc(w: ^World) -> bool {
    return world_level(w).play_world != nil
}

// The play copy of `level`, registered, with every view of the level switched to it.
world_play_copy :: proc(level: ^World) -> ^World {
    p := new(World, app.allocators.perm)
    world_init(p)
    p.entities      = level.entities   // plain values; strings are interned asset keys or inline
    p.settings      = level.settings
    p.light_group_override = level.light_group_override
    p.title         = strings.clone(level.title, app.allocators.perm)
    p.play_source   = level
    level.play_world = p
    append(&worlds, p)
    for v in views do if v.world == level do v.world = p
    log.infof("Play: %s", level.title)
    return p
}

// Undoes world_play_copy: the play world's views go back to its level, the two are unlinked, and the
// copy is queued to close (next frame, through the normal close path).
world_play_discard :: proc(p: ^World) {
    level := p.play_source
    for v in views do if v.world == p { v.world = level; v.camera_entity = {} }   // the handle was the play world's
    level.play_world = nil
    p.play_source    = nil   // a closing leftover now, not a play world
    world_request_close(p)
    log.infof("Stop: %s", level.title)
}

// A play world's script asked for another level (World.switch_level): a play world loaded from `path` takes
// p's place. It keeps p's level (so Stop still goes back to the level being edited), p's views and p's game
// state (world_game.odin); p is unlinked and queued to close like a stopped copy. nil (logged) if `path`
// doesn't load, and p plays on. The edited level is never touched: switching is a play-world thing.
world_play_switch :: proc(p: ^World, path: string) -> ^World {
    level := p.play_source
    q := new(World, app.allocators.perm)
    world_init(q)
    if !scene_load(q, path) {
        world_shutdown(q)
        free(q, app.allocators.perm)
        return nil
    }
    q.title       = strings.clone(filepath.base(path), app.allocators.perm)
    q.game        = p.game
    q.switched    = true
    q.play_source = level
    level.play_world = q
    p.play_source    = nil   // a closing leftover now, not a play world
    append(&worlds, q)
    for v in views do if v.world == p {   // the camera handle was p's: a view showing the game (ui_game_enter) shows q's camera
        v.world = q
        v.camera_entity = v.camera_entity != {} ? world_game_camera(q) : {}
    }
    world_request_close(p)
    log.infof("Switch level: %s -> %s", p.title, q.title)
    return q
}

// The world whose baked probes light `w`. A copy has none of its own and lights with its level's; a play world
// a switch loaded from another level's file lights with that file's, which it loaded itself.
world_lighting :: proc(w: ^World) -> ^World {
    return w.switched ? w : world_level(w)
}

// The camera the game renders and listens through: the first enabled camera entity. Zero if there's none.
world_game_camera :: proc(w: ^World) -> Entity_Handle {
    it := hm.iterator_make(&w.entities)
    for e, h in hm.iterate(&it) do if entity_is_game_camera(e) do return h
    return {}
}

// Whether `e` can be the game camera: a camera, and enabled.
entity_is_game_camera :: proc(e: ^Entity) -> bool {
    return e.camera_type != .None && entity_enabled(e)
}

// Paused: the world script's update stops (later, every runtime system's step). Editing still works.
world_pause_toggle :: proc(w: ^World) {
    if p := world_level(w).play_world; p != nil do p.paused = !p.paused
}

// While paused: run exactly one frame of the game on the next tick (F10).
world_step :: proc(w: ^World) {
    if p := world_level(w).play_world; p != nil && p.paused do p.step = true
}

// Once per frame, before any game system runs: decides whether each play world advances this frame
// (`ticks`), consuming a pending step, and advances its game clock (`time`) by `dt` if so. Game systems
// check `w.ticks`, never `paused` directly, so a step moves all of them by the same one frame.
world_play_tick :: proc(dt: f64) {
    for w in worlds {
        w.ticks = w.play_source != nil && (!w.paused || w.step)
        w.step  = false
        w.dt = w.ticks ? f32(dt) : 0
        if w.ticks {
            w.time += dt
            clear(&w.debug_lines)   // last tick's game lines; this tick's systems draw them again
        }
    }
}
