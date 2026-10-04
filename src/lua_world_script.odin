package blimp

import "core:c"
import "core:fmt"
import "core:log"
import lua "vendor:lua/5.1"

// World scripts: each world's [world] `script` (a .lua file) runs while the world is playing.
//
//   function World.start()       / function 世界.开始()          -- once, at Play (or when the script changes)
//   function World.update(dt)    / function 世界.更新(时间差)    -- every frame
//
// Each script runs in its own environment (lua_script_load, lua.odin) — a table that falls back to _G — so
// two open worlds' scripts can't clobber each other's globals. Its World (= 世界) is its own table too,
// falling back to the shared World bindings, so World.find etc. work and its hooks never land in the shared table.
// While a world's script runs, the @(lua) world/entity procs (lua_api_*.odin) act on that world
// (lua_world()). Engine hooks (引擎.更新 …) have no world: World/Entity procs called there log an error and do nothing.
//
// Lua never holds state that matters (CLAUDE.md): script edits to entities go straight into the
// world, and a script can't create globals (assigning an undeclared name is an error). A script loads its
// modules with require / 引入 by project-relative path; they run in its env (lua_script_load). A script error is logged once and stops that world's script until it's changed or reopened.
Lua_World_Script :: struct {
    loaded: sbuf256,   // the path these refs were loaded from ("" = none); compared each frame to settings.script
    env:    c.int,     // registry refs; <= 0 = none (refs start at 1, so a zeroed world has none)
    start:  c.int,
    update: c.int,
    failed: bool,      // errored: stays stopped until it reloads (path change, hot reload, next Play)
    missed: [16]u32,   // hashes of names World.get didn't find, so each warns once per load (lua_api_world.odin)
    missed_count: int,
}

// The world the @(lua) world/entity procs act on: the one whose script is running (or the one blimpctl
// pointed them at). Outside any, there is none: logs once per frame which proc needed one, and the proc
// does nothing.
lua_world :: proc(loc := #caller_location) -> (^World, bool) {
    if lua_current_world != nil do return lua_current_world, true
    if lua_no_world_frame != timer_frame_index() {
        lua_no_world_frame = timer_frame_index()
        log.errorf("Lua: %s needs a world; call it from a world script (World.start / World.update)", loc.procedure)
    }
    return nil, false
}

@(private="file") lua_current_world:  ^World
@(private="file") lua_no_world_frame: u64 = max(u64)

// Points the @(lua) world/entity procs at `w` and returns what they pointed at, to put back.
// For running Lua from outside a world script (blimpctl lua).
lua_world_target :: proc(w: ^World) -> (prev: ^World) {
    prev = lua_current_world
    lua_current_world = w
    return
}

// Once per frame, after the engine's update hook, for every play world (world_play.odin): (re)load its
// script if the path changed — on the first frame of Play, that's loading it and running start — then
// run its update if the world advances this frame (w.ticks: not paused, or stepping on F10). Levels
// being edited don't run scripts.
lua_worlds_update :: proc(dt: f64) {
    for w in worlds {
        if w.play_source == nil do continue
        lua_world_script_sync(w)
        s := &w.script
        if !w.ticks || s.failed || s.update <= 0 do continue   // refs start at 1; 0 (fresh world) or NOREF = none
        if !lua_world_call(w, s.update, dt) do lua_world_script_stop(w, "update")
    }
}

// Frees a world's script state (the world is closing).
lua_world_script_unload :: proc(w: ^World) {
    L := lua_system.L
    s := &w.script
    if L != nil do for ref in ([]c.int{s.env, s.start, s.update}) do if ref > 0 do lua.L_unref(L, lua.REGISTRYINDEX, ref)
    s^ = {env = lua.NOREF, start = lua.NOREF, update = lua.NOREF}
}

// Loads the script if settings.script differs from what's loaded (opened, edited, undone), then runs start.
@(private="file")
lua_world_script_sync :: proc(w: ^World) {
    s := &w.script
    want := sbuf_str(&w.settings.script)
    if want == sbuf_str(&s.loaded) do return
    lua_world_script_unload(w)
    sbuf_set(&s.loaded, want)
    if want == "" || lua_system.L == nil do return

    L := lua_system.L
    top := lua.gettop(L)
    defer lua.settop(L, top)

    env, ok := lua_script_load(L, want, "World", "世界")
    if !ok {
        log.errorf("World script %s (%s): %s", want, w.title, lua.tostring(L, -1))
        s.failed = true
        return
    }
    s.env = env

    // Run the chunk (its top level defines the hooks) with this world as the context.
    prev := lua_current_world
    lua_current_world = w
    rc := lua.pcall(L, 0, 0, 0)
    lua_current_world = prev
    if rc != 0 {
        log.errorf("World script %s (%s): %s", want, w.title, lua.tostring(L, -1))
        s.failed = true
        return
    }

    // The hooks live in the env's own World table (lua_hook_ref's raw lookups skip the shared bindings).
    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(s.env))
    lua.getfield(L, -1, "World")
    s.start  = lua_hook_ref(L, "start", "开始")
    s.update = lua_hook_ref(L, "update", "更新")
    log.infof("World script %s loaded for %s", want, w.title)
    if s.start > 0 && !lua_world_call(w, s.start) do lua_world_script_stop(w, "start")
}


// Calls a hook with `w` as the world context. False (error logged) on a Lua error.
@(private="file")
lua_world_call :: proc(w: ^World, ref: c.int, args: ..f64) -> bool {
    prev := lua_current_world
    lua_current_world = w
    defer lua_current_world = prev
    return lua_hook_call(lua_system.L, ref, fmt.tprintf("world script %s (%s)", sbuf_str(&w.script.loaded), w.title), ..args)
}

@(private="file")
lua_world_script_stop :: proc(w: ^World, hook: string) {
    w.script.failed = true
    log.warnf("World script for %s stopped after an error in %s; save a fix (hot reload) or stop and play again", w.title, hook)
}
