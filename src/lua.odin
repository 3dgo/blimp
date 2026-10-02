package blimp

import "core:log"
import "core:c"
import "core:math/linalg"
import lua "vendor:lua/5.1"

Lua_System :: struct {
    L: ^lua.State,

    // Engine hooks (引擎.开始/更新/完结 = Blimp.start/update/finish): registry refs, resolved once
    // main.lua has run; <= 0 = none.
    start, update, finish: c.int,
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
    lua_main_load()
}

LUA_MAIN_SCRIPT :: "assets/scripts/main.lua"

// Runs main.lua and resolves the engine hooks it defines. At init, and again when it changes on disk
// (asset_hot_reload.odin), which also reruns its start hook.
lua_main_load :: proc() {
    L := lua_system.L
    for ref in ([]c.int{lua_system.start, lua_system.update, lua_system.finish}) do if ref > 0 do lua.L_unref(L, lua.REGISTRYINDEX, ref)
    lua_system.start, lua_system.update, lua_system.finish = lua.NOREF, lua.NOREF, lua.NOREF

    lr := lua.L_dofile(L, LUA_MAIN_SCRIPT); check_luar(lr, "Failed to load main lua file", L)

    lua.getglobal(L, "Blimp")
    lua_system.start  = lua_hook_ref(L, "start", "开始")
    lua_system.update = lua_hook_ref(L, "update", "更新")
    lua_system.finish = lua_hook_ref(L, "finish", "完结")
    lua.pop(L, 1)
}

// Hot reload: the .lua at `path` (project-relative) changed on disk. Lua holds no state (CLAUDE.md), so
// rerunning a script from the top is safe: every play world running it reloads it next frame, start
// included, even one stopped by an error; main.lua reruns now.
lua_reload_script :: proc(path: string) {
    if lua_system.L == nil do return
    for w in worlds do if w.play_source != nil && sbuf_str(&w.script.loaded) == path {
        lua_world_script_unload(w)   // clears `loaded` and `failed`, so the next sync loads it again
        log.infof("Hot reload: %v (%v)", path, w.title)
    }
    if path == LUA_MAIN_SCRIPT {
        log.infof("Hot reload: %v", path)
        lua_main_load()
        lua_start()
    }
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

//================================ Lua Functions =================================
lua_vec3_length :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    v := lua_arg_vec3(L, 1)^
    lua.pushnumber(L, lua.Number(linalg.length(v)))
    return 1
}

lua_vec3_dot :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    a := lua_arg_vec3(L, 1)^
    b := lua_arg_vec3(L, 2)^
    lua.pushnumber(L, lua.Number(linalg.dot(a, b)))
    return 1
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

lua_arg_vec3 :: #force_inline proc "c"(L: ^lua.State, idx: c.int) -> ^vec3 {
    return (^vec3)(lua.topointer(L, idx))
}

check_luar :: proc(lr: c.int, msg: string, L: ^lua.State, location := #caller_location) {
    if lr != 0 {
        log.errorf("Lua Error: {}: {}", msg, lua.tostring(L, -1), location = location)
        lua.pop(L, 1)
    }
}

@(lua=my_log, table=Blimp)
my_log :: proc(msg: string) {
    log.info(msg)
}

@(lua, table=Blimp)
my_log_2 :: proc(msg: string) -> string {
    log.info(msg)
    return "hello"
}

@(lua=Test)
Test_Struct :: struct {
    a: f32,
    b: u32,
    c: f64,
    d: i32,
}