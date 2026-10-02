package blimp

import "core:log"
import "core:strings"
import hm "core:container/handle_map"

// Play mode: Play runs a copy of the world as the game, and Stop throws the copy away. The level is
// never touched while playing, so nothing the game does can leak into it: script changes, editor
// edits made during play, spawned or deleted entities, and later physics, animation and audio state.
//
// - The play world is an ordinary World in `worlds`, built from the level (the same entities and
//   settings). It has no save_path, so it can't be saved, and its undo steps and arena go when it closes.
// - Every view of the level switches to show the play world (the same windows, like Unity), and back
//   on Stop. Editor state pinned to the level (panels, World Settings) is retargeted
//   with it (ui_retarget_world).
// - World scripts run only in play worlds (lua_worlds_update): Play loads the script and runs init.
// - Runtime systems that land later are built with the play world and freed when it closes.
//
// level.play_world → the running copy; play.play_source → its level. Both nil when not playing.

// The world that's saved and edited: the level a play world was copied from, else w itself.
world_level :: proc(w: ^World) -> ^World {
    return w.play_source != nil ? w.play_source : w
}

world_playing :: proc(w: ^World) -> bool {
    return world_level(w).play_world != nil
}

// Starts playing `w`'s level.
world_play :: proc(w: ^World) {
    level := world_level(w)
    if level.play_world != nil do return

    p := new(World, app.allocators.perm)
    world_init(p)
    p.entities      = level.entities   // plain values; strings point into the asset arena or are inline
    p.settings      = level.settings
    p.active        = level.active
    p.select_anchor = level.select_anchor
    p.title         = strings.clone(level.title, app.allocators.perm)
    p.play_source   = level
    level.play_world = p
    world_render_create(p)
    append(&worlds, p)

    for v in views do if v.world == level do v.world = p
    ui_retarget_world(level, p)
    log.infof("Play: %s", level.title)
}

// Stops `w`'s level playing: its views go back to the level, and the play world closes (next frame,
// through the normal close path).
world_stop :: proc(w: ^World) {
    level := world_level(w)
    p := level.play_world
    if p == nil do return

    for v in views do if v.world == p { v.world = level; v.game_camera = {} }   // the handle was the play world's
    ui_retarget_world(p, level)
    lua_world_script_unload(p)   // its script stops now, not when it closes
    level.play_world = nil
    p.play_source    = nil       // a closing leftover now, not a play world
    world_request_close(p)
    log.infof("Stop: %s", level.title)
}

// The camera the game renders through (game mode, ui_game.odin): the first enabled camera entity.
// Zero if there's none.
world_game_camera :: proc(w: ^World) -> Entity_Handle {
    it := hm.iterator_make(&w.entities)
    for e, h in hm.iterate(&it) do if e.camera_type != .None && .Enabled in e.basic_flags do return h
    return {}
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
// (`ticks`), consuming a pending step. Game systems check `w.ticks`, never `paused` directly, so a step
// moves all of them by the same one frame.
world_play_tick :: proc() {
    for w in worlds {
        w.ticks = w.play_source != nil && (!w.paused || w.step)
        w.step  = false
    }
}
