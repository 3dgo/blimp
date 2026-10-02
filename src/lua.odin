package blimp

import "core:log"
import "core:c"
import "core:math/linalg"
import lua "vendor:lua/5.1"

Lua_System :: struct {
    L: ^lua.State,

    wire_hook: Lua_Hook,
    start_hook: Lua_Hook,
    update_hook: Lua_Hook,
    end_hook: Lua_Hook,
}
lua_system: Lua_System

Lua_Hook :: struct {
    ref: c.int,
    table: cstring,
    field: cstring,
}

lua_init :: proc() {
    lua_system.L = lua.L_newstate()
    if lua_system.L == nil {
        log.error("Failed to create Lua state")
        return
    }

    lua.L_openlibs(lua_system.L)
    
    lr := lua.L_dofile(lua_system.L, "assets_engine/scripts/setup.lua"); check_luar(lr, "Failed to load setup lua file", lua_system.L)
    _lua_register_all_bindings(lua_system.L)
    lr = lua.L_dofile(lua_system.L, "assets/scripts/main.lua"); check_luar(lr, "Failed to load main lua file", lua_system.L)
    
    lua_hook_call_direct(lua_system.L, "Blimp", "_wire")
    
    lua_system.update_hook = lua_hook_get(lua_system.L, "Blimp", "_update")
}

lua_shutdown :: proc() {
    if lua_system.L != nil {
        lua.close(lua_system.L)
        lua_system.L = nil
    }
}

lua_start :: proc() {
    lua_hook_call_direct(lua_system.L, "Blimp", "_start")
}

lua_update :: proc(delta_sec: f64) {
    lua_hook_call_f64(lua_system.L, lua_system.update_hook, delta_sec)
}

lua_finish :: proc() {
    lua_hook_call_direct(lua_system.L, "Blimp", "_finish")
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
lua_hook_get :: proc(L: ^lua.State, table: cstring, field: cstring) -> Lua_Hook {
    hook := Lua_Hook {
        ref = lua.NOREF,
        table = table,
        field = field,
    }

    lua.getglobal(L, table)
    lua.getfield(L, -1, field)
    lua.remove(L, -2)

    if lua.type(L, -1) != .FUNCTION {
        lua.pop(L, 1)
        return hook
    }
    hook.ref = lua.L_ref(L, lua.REGISTRYINDEX)
    return hook
}

lua_hook_free :: proc(L: ^lua.State, hook: ^Lua_Hook) {
    if hook.ref != lua.NOREF {
        lua.L_unref(L, lua.REGISTRYINDEX, hook.ref)
        hook.ref = lua.NOREF
    }
}

lua_hook_call_direct :: proc(L: ^lua.State, table: cstring, field: cstring) {
    lua.getglobal(L, table)
    lua.getfield(L, -1, field)
    lua.remove(L, -2)
    if lua.isfunction(L, -1) {
        rc := lua.pcall(L, 0, 0, 0); check_luar(rc, "Failed to call hook function", L)
    } else {
        lua.pop(L, 1)
    }
}

lua_hook_call :: proc(L: ^lua.State, hook: Lua_Hook) {
    if hook.ref == lua.NOREF do return

    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(hook.ref))
    rc := lua.pcall(L, 0, 0, 0); check_luar(rc, "Failed to call hook function", L)
}

lua_hook_call_f64 :: proc(L: ^lua.State, hook: Lua_Hook, param1: f64) {
    if hook.ref == lua.NOREF do return

    lua.rawgeti(L, lua.REGISTRYINDEX, lua.Integer(hook.ref))
    lua.pushnumber(L, lua.Number(param1))
    rc := lua.pcall(L, 1, 0, 0); check_luar(rc, "Failed to call hook function", L)
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