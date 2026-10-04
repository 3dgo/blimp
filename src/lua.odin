package blimp

import "core:log"
import "core:c"
import "core:strings"
import lua "vendor:lua/5.1"
import "common"

Lua_System :: struct {
    L: ^lua.State,

    // Engine hooks (引擎.开始/更新/完结 = Blimp.start/update/finish): registry refs, resolved once
    // main.lua has run; <= 0 = none. env: main.lua's environment (lua_script_load).
    env, start, update, finish: c.int,
}
lua_system: Lua_System

lua_init :: proc() {
    lua_system.L = lua.L_newstate()
    if lua_system.L == nil {
        log.error("Failed to create Lua state")
        return
    }
    L := lua_system.L

    lua.L_openlibs(L)

    lr := lua.L_dofile(L, "assets_engine/scripts/setup.lua"); check_luar(lr, "Failed to load setup lua file", L)
    _lua_register_all_bindings(L)
    common.luacn_scan_folder("assets")   // .luacn edited since the last build; app_play does this too
    lua_main_load()
}

LUA_MAIN_SCRIPT :: "assets/scripts/main.lua"

// Runs main.lua and resolves the engine hooks it defines. At init, and again on hot reload
// (lua_reload_scripts), which also reruns its start hook. It loads like a world script (lua_script_load): its
// own env, its own 引擎 table for the hooks, require / 引入 by path, strict.
lua_main_load :: proc() {
    L := lua_system.L
    for ref in ([]c.int{lua_system.env, lua_system.start, lua_system.update, lua_system.finish}) do if ref > 0 do lua.L_unref(L, lua.REGISTRYINDEX, ref)
    lua_system.env, lua_system.start, lua_system.update, lua_system.finish = lua.NOREF, lua.NOREF, lua.NOREF, lua.NOREF

    top := lua.gettop(L)
    defer lua.settop(L, top)
    env, ok := lua_script_load(L, LUA_MAIN_SCRIPT, "Blimp", "引擎")
    if ok {
        lua_system.env = env
        ok = lua.pcall(L, 0, 0, 0) == 0
    }
    if !ok {
        log.errorf("Main script %s: %s", LUA_MAIN_SCRIPT, lua.tostring(L, -1))
        return
    }
    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(lua_system.env))
    lua.getfield(L, -1, "Blimp")
    lua_system.start  = lua_hook_ref(L, "start", "开始")
    lua_system.update = lua_hook_ref(L, "update", "更新")
    lua_system.finish = lua_hook_ref(L, "finish", "完结")
}

// Loads the script at `path` (project-relative) the way every script runs, world scripts and main.lua alike,
// and leaves its chunk on the stack, ready to call. Its env is a table that falls back to _G, holding:
//   hooks / hooks_zh  its own table (falling back to the shared bindings table `hooks`), where its hooks go
//   require / 引入    modules by project-relative path, run in this env (LUA_ENV_REQUIRE)
// and it's strict: assigning an undeclared name is an error (LUA_ENV_NEWINDEX), since a forgotten 令 / 本地
// would otherwise keep a value between frames, state Lua mustn't hold. Returns the env's registry ref; false
// with the error message on the stack if the file doesn't load.
lua_script_load :: proc(L: ^lua.State, path: string, hooks, hooks_zh: cstring) -> (env: c.int, ok: bool) {
    if lua.L_loadfile(L, strings.clone_to_cstring(path, context.temp_allocator)) != .OK do return lua.NOREF, false
    // env = setmetatable({}, {__index = _G})
    lua.newtable(L)
    lua.newtable(L)
    lua.getglobal(L, "_G")
    lua.setfield(L, -2, "__index")
    lua.setmetatable(L, -2)
    // env[hooks] = env[hooks_zh] = setmetatable({}, {__index = <shared hooks table>})
    lua.newtable(L)
    lua.newtable(L)
    lua.getglobal(L, hooks)
    lua.setfield(L, -2, "__index")
    lua.setmetatable(L, -2)
    lua.pushvalue(L, -1)
    lua.setfield(L, -3, hooks)
    lua.setfield(L, -2, hooks_zh)
    // env.require = env.引入
    if lua.L_loadstring(L, LUA_ENV_REQUIRE) == .OK {
        lua.call(L, 0, 1)
        lua.pushvalue(L, -2)
        lua.call(L, 1, 1)
        lua.pushvalue(L, -1)
        lua.setfield(L, -3, "require")
        lua.setfield(L, -2, "引入")
    } else do lua.pop(L, 1)
    // Strict, last, so the fields above could still be set.
    lua.getmetatable(L, -1)
    if lua.L_loadstring(L, LUA_ENV_NEWINDEX) == .OK do lua.call(L, 0, 1)
    lua.setfield(L, -2, "__newindex")
    lua.pop(L, 1)
    lua.pushvalue(L, -1)
    env = lua.L_ref(L, lua.REGISTRYINDEX)
    lua.setfenv(L, -2)
    return env, true
}

// A script env's __newindex (lua_script_load): assigning an undeclared name is an error, reported at the script
// line (level 2).
@(private="file")
LUA_ENV_NEWINDEX :: `return function(_, name) error("assignment to undeclared variable '" .. tostring(name) .. "'; declare it local", 2) end`

// A script's require (= 引入), made per load from its env. `require("assets/characters/player")` runs
// assets/characters/player.lua (".lua" optional; any project-relative path, so modules live anywhere under
// assets/) with that env as its environment: the strict rule covers modules too, and two playing worlds never
// share a module's upvalues. Cached for this load only, so Play and hot reload always load fresh copies.
@(private="file")
LUA_ENV_REQUIRE :: `return function(env)
    local loaded = {}
    return function(name)
        local path = tostring(name):gsub("%.lua$", "") .. ".lua"
        local m = loaded[path]
        if m == false then error("require: circular require of '" .. path .. "'", 2) end
        if m ~= nil then return m end
        local chunk, err = loadfile(path)
        if not chunk then error("require: " .. err, 2) end
        setfenv(chunk, env)
        loaded[path] = false
        m = chunk(path)
        if m == nil then m = true end
        loaded[path] = m
        return m
    end
end`

// Hot reload: these .lua files (project-relative) changed on disk. Which script requires which module isn't
// tracked, and Lua holds no state (CLAUDE.md), so rerunning every script from the top is safe and simplest:
// main.lua reruns now, start hook included, and every play world with a script reloads it next frame, start
// included, even one stopped by an error.
lua_reload_scripts :: proc(paths: []string) {
    if lua_system.L == nil || len(paths) == 0 do return
    log.infof("Hot reload: %v", paths)
    lua_main_load()
    lua_start()
    for w in worlds do if w.play_source != nil && sbuf_str(&w.script.loaded) != "" do lua_world_script_unload(w)   // clears `loaded` and `failed`: the next sync loads it again
}

lua_shutdown :: proc() {
    if lua_system.L != nil {
        lua.close(lua_system.L)
        lua_system.L = nil
    }
}

lua_start :: proc() {
    if lua_system.start > 0 do lua_hook_call(lua_system.L, lua_system.start, "engine start")
}

lua_update :: proc(delta_sec: f64) {
    if lua_system.update > 0 do lua_hook_call(lua_system.L, lua_system.update, "engine update", delta_sec)
}

lua_finish :: proc() {
    if lua_system.finish > 0 do lua_hook_call(lua_system.L, lua_system.finish, "engine finish")
}

//================================ Helpers ====================================
// A registry ref to the function `name_zh` or `name` in the table on top of the stack (lua.NOREF if
// neither is one); the stack is left as it was. Raw lookups, so a field the table only inherits is
// never a hook. Engine hooks (引擎.开始) and world hooks (世界.开始) both resolve this way.
lua_hook_ref :: proc(L: ^lua.State, name, name_zh: cstring) -> c.int {
    if !lua.istable(L, -1) do return lua.NOREF
    for n in ([]cstring{name_zh, name}) {
        lua.pushstring(L, n)
        lua.rawget(L, -2)
        if lua.isfunction(L, -1) do return lua.L_ref(L, lua.REGISTRYINDEX)
        lua.pop(L, 1)
    }
    return lua.NOREF
}

// Calls a hook ref with its args. False (error logged, naming `what`) on a Lua error.
lua_hook_call :: proc(L: ^lua.State, ref: c.int, what: string, args: ..f64) -> bool {
    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(ref))
    for a in args do lua.pushnumber(L, lua.Number(a))
    if lua.pcall(L, c.int(len(args)), 0, 0) != 0 {
        log.errorf("Lua error in %s: %s", what, lua.tostring(L, -1))
        lua.pop(L, 1)
        return false
    }
    return true
}

check_luar :: proc(lr: c.int, msg: string, L: ^lua.State, location := #caller_location) {
    if lr != 0 {
        log.errorf("Lua Error: {}: {}", msg, lua.tostring(L, -1), location = location)
        lua.pop(L, 1)
    }
}
