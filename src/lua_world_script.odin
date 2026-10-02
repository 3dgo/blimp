package blimp

import "core:c"
import "core:log"
import "core:strings"
import lua "vendor:lua/5.1"

// World scripts: each world's [world] `script` (a .lua file) runs while the world is playing.
//
//   function init()        / function 初始化()          -- once, at Play (or when the script changes)
//   function update(dt)    / function 更新(时间差)      -- every frame
//
// Each script runs in its own environment — a table that falls back to _G — so two open worlds'
// scripts can't clobber each other's globals, and its hooks are plain functions in it (not fields of
// the shared 世界 bindings table). While a world's script runs, the @(lua) world/entity procs act on
// that world (lua_world()); engine hooks (引擎.更新 …) still act on game_world.
//
// Lua never holds state that matters (CLAUDE.md): script edits to entities go straight into the
// world. A script error is logged once and stops that world's script until it's changed or reopened.
Lua_World_Script :: struct {
    loaded: sbuf256,   // the path these refs were loaded from ("" = none); compared each frame to settings.script
    env:    c.int,     // registry refs; <= 0 = none (refs start at 1, so a zeroed world has none)
    init:   c.int,
    update: c.int,
    failed: bool,      // errored: stays stopped until the path changes
}

// The world the @(lua) world/entity procs act on: the one whose script is running, else game_world.
lua_world :: proc() -> ^World {
    return lua_current_world != nil ? lua_current_world : &game_world
}

@(private="file")
lua_current_world: ^World

// Once per frame, after the engine's update hook, for every play world (world_play.odin): (re)load its
// script if the path changed — on the first frame of Play, that's loading it and running init — then
// run its update if the world advances this frame (w.ticks: not paused, or stepping on F10). Levels
// being edited don't run scripts.
lua_worlds_update :: proc(dt: f64) {
    for w in worlds {
        if w.play_source == nil do continue
        lua_world_script_sync(w)
        s := &w.script
        if !w.ticks || s.failed || s.update <= 0 do continue   // refs start at 1; 0 (fresh world) or NOREF = none
        if !lua_world_call(w, s.update, dt, true) do lua_world_script_stop(w, "update")
    }
}

// Frees a world's script state (the world is closing).
lua_world_script_unload :: proc(w: ^World) {
    L := lua_system.L
    s := &w.script
    if L != nil do for ref in ([]c.int{s.env, s.init, s.update}) do if ref > 0 do lua.L_unref(L, lua.REGISTRYINDEX, ref)
    s^ = {env = lua.NOREF, init = lua.NOREF, update = lua.NOREF}
}

// Loads the script if settings.script differs from what's loaded (opened, edited, undone), then runs init.
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

    if lua.L_loadfile(L, strings.clone_to_cstring(want, context.temp_allocator)) != .OK {
        log.errorf("World script %s (%s): %s", want, w.title, lua.tostring(L, -1))
        s.failed = true
        return
    }
    // env = setmetatable({}, {__index = _G}); setfenv(chunk, env)
    lua.newtable(L)
    lua.newtable(L)
    lua.getglobal(L, "_G")
    lua.setfield(L, -2, "__index")
    lua.setmetatable(L, -2)
    lua.pushvalue(L, -1)
    s.env = lua.L_ref(L, lua.REGISTRYINDEX)
    lua.setfenv(L, -2)

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

    s.init   = lua_world_script_hook(L, s.env, "init", "初始化")
    s.update = lua_world_script_hook(L, s.env, "update", "更新")
    log.infof("World script %s loaded for %s", want, w.title)
    if s.init > 0 && !lua_world_call(w, s.init, 0, false) do lua_world_script_stop(w, "init")
}

// A registry ref to the env's function `name` or `name_zh` (lua.NOREF if neither is a function).
@(private="file")
lua_world_script_hook :: proc(L: ^lua.State, env: c.int, name, name_zh: cstring) -> c.int {
    for n in ([]cstring{name_zh, name}) {
        lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(env))
        lua.getfield(L, -1, n)
        lua.remove(L, -2)
        if lua.isfunction(L, -1) do return lua.L_ref(L, lua.REGISTRYINDEX)
        lua.pop(L, 1)
    }
    return lua.NOREF
}

// Calls a hook with `w` as the world context. False (error logged) on a Lua error.
@(private="file")
lua_world_call :: proc(w: ^World, ref: c.int, dt: f64, pass_dt: bool) -> bool {
    L := lua_system.L
    prev := lua_current_world
    lua_current_world = w
    defer lua_current_world = prev

    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(ref))
    if pass_dt do lua.pushnumber(L, lua.Number(dt))
    if lua.pcall(L, pass_dt ? 1 : 0, 0, 0) != 0 {
        log.errorf("World script %s (%s): %s", sbuf_str(&w.script.loaded), w.title, lua.tostring(L, -1))
        lua.pop(L, 1)
        return false
    }
    return true
}

@(private="file")
lua_world_script_stop :: proc(w: ^World, hook: string) {
    w.script.failed = true
    log.warnf("World script for %s stopped after an error in %s; change the script path or reopen the world to retry", w.title, hook)
}
