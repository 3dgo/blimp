// AUTO GENERATED. DO NOT EDIT

package blimp

@(require) import "base:intrinsics"
@(require) import "core:strings"
@(require) import "core:c"
@(require) import lua "vendor:lua/5.1"

//==================== FFI Push Helpers ====================

@(private)
_lua_push_arr :: proc(L: ^lua.State, global: cstring, v: [$N]$T) {
    lua.getglobal(L, global)
    for elem in v {
        when intrinsics.type_is_float(T) {
            lua.pushnumber(L, lua.Number(elem))
        } else {
            lua.pushinteger(L, lua.Integer(elem))
        }
    }
    if lua.pcall(L, N, 1, 0) != c.int(lua.Status.OK) {
        err := lua.tostring(L, -1)
        lua.pop(L, 1)
        lua.L_error(L, "FFI push failed calling global '%s' (is it exposed in setup.lua?): %s", global, err)
    }
}

_lua_push_ffi_ivec3 :: proc(L: ^lua.State, v: ivec3) { _lua_push_arr(L, "IVec3", v) }
_lua_push_ffi_ivec2 :: proc(L: ^lua.State, v: ivec2) { _lua_push_arr(L, "IVec2", v) }
_lua_push_ffi_vec2 :: proc(L: ^lua.State, v: vec2) { _lua_push_arr(L, "Vec2", v) }
_lua_push_ffi_ivec4 :: proc(L: ^lua.State, v: ivec4) { _lua_push_arr(L, "IVec4", v) }
_lua_push_ffi_vec3 :: proc(L: ^lua.State, v: vec3) { _lua_push_arr(L, "Vec3", v) }
_lua_push_ffi_mat3 :: proc(L: ^lua.State, v: mat3) { _lua_push_arr(L, "Mat3", transmute([9]f32)v) }
_lua_push_ffi_quat :: proc(L: ^lua.State, v: quat) { _lua_push_arr(L, "Quat", transmute([4]f32)v) }
_lua_push_ffi_vec4 :: proc(L: ^lua.State, v: vec4) { _lua_push_arr(L, "Vec4", v) }
_lua_push_ffi_mat4 :: proc(L: ^lua.State, v: mat4) { _lua_push_arr(L, "Mat4", transmute([16]f32)v) }

//==================== Generate Structs ====================

// Binding odin struct: Test_Struct to lua table.
_lua_push_table_Test_Struct :: proc(L: ^lua.State, v: Test_Struct) {
    lua.createtable(L, 0, 4)
    lua.pushnumber(L, lua.Number(v.a))
    lua.setfield(L, -2, "a")
    lua.pushinteger(L, lua.Integer(v.b))
    lua.setfield(L, -2, "b")
    lua.pushnumber(L, lua.Number(v.c))
    lua.setfield(L, -2, "c")
    lua.pushinteger(L, lua.Integer(v.d))
    lua.setfield(L, -2, "d")
}

_lua_read_table_Test_Struct :: proc(L: ^lua.State, idx: c.int) -> Test_Struct {
    v: Test_Struct
    lua.getfield(L, idx, "a")
    v.a = f32(lua.L_checknumber(L, -1))
    lua.pop(L, 1)
    lua.getfield(L, idx, "b")
    v.b = u32(lua.L_checkinteger(L, -1))
    lua.pop(L, 1)
    lua.getfield(L, idx, "c")
    v.c = f64(lua.L_checknumber(L, -1))
    lua.pop(L, 1)
    lua.getfield(L, idx, "d")
    v.d = i32(lua.L_checkinteger(L, -1))
    lua.pop(L, 1)
    return v
}

// Binding odin struct: Cg_Test_Entity to lua table.
_lua_push_table_Cg_Test_Entity :: proc(L: ^lua.State, v: Cg_Test_Entity) {
    lua.createtable(L, 0, 4)
    _lua_push_ffi_vec3(L, v.position)
    lua.setfield(L, -2, "position")
    _lua_push_ffi_vec2(L, v.tile)
    lua.setfield(L, -2, "tile")
    lua.pushnumber(L, lua.Number(v.speed))
    lua.setfield(L, -2, "speed")
    lua.pushboolean(L, b32(v.active))
    lua.setfield(L, -2, "active")
    lua.getfield(L, lua.REGISTRYINDEX, "_mt_Cg_Test_Entity")
    if lua.type(L, -1) != .NIL { lua.setmetatable(L, -2) } else { lua.pop(L, 1) }
}

_lua_read_table_Cg_Test_Entity :: proc(L: ^lua.State, idx: c.int) -> Cg_Test_Entity {
    v: Cg_Test_Entity
    lua.getfield(L, idx, "position")
    v.position = (cast(^vec3)lua.topointer(L, -1))^
    lua.pop(L, 1)
    lua.getfield(L, idx, "tile")
    v.tile = (cast(^vec2)lua.topointer(L, -1))^
    lua.pop(L, 1)
    lua.getfield(L, idx, "speed")
    v.speed = f32(lua.L_checknumber(L, -1))
    lua.pop(L, 1)
    lua.getfield(L, idx, "active")
    v.active = bool(lua.toboolean(L, -1))
    lua.pop(L, 1)
    return v
}

//==================== Generate Procs ====================

// Binding odin proc: entity_get_number to lua function: get_number.
_lua_entity_get_number :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    field := string(lua.L_checkstring(L, 2))
    r0 := entity_get_number(handle, field)
    lua.pushnumber(L, lua.Number(r0))
    return 1
}

// Binding odin proc: cg_test_mat4_trace to lua function: mat4_trace.
_lua_cg_test_mat4_trace :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    v := (cast(^mat4)lua.topointer(L, 1))^
    r0 := cg_test_mat4_trace(v)
    lua.pushnumber(L, lua.Number(r0))
    return 1
}

// Binding odin proc: my_log to lua function: my_log.
_lua_my_log :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    msg := string(lua.L_checkstring(L, 1))
    my_log(msg)
    return 0
}

// Binding odin proc: cg_test_entity_echo to lua function: entity_echo.
_lua_cg_test_entity_echo :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    e := _lua_read_table_Cg_Test_Entity(L, 1)
    r0 := cg_test_entity_echo(e)
    _lua_push_table_Cg_Test_Entity(L, r0)
    return 1
}

// Binding odin proc: entity_get_quat to lua function: get_quat.
_lua_entity_get_quat :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    field := string(lua.L_checkstring(L, 2))
    r0 := entity_get_quat(handle, field)
    _lua_push_ffi_quat(L, r0)
    return 1
}

// Binding odin proc: entity_valid to lua function: valid.
_lua_entity_valid :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    r0 := entity_valid(handle)
    lua.pushboolean(L, b32(r0))
    return 1
}

// Binding odin proc: my_log_2 to lua function: my_log_2.
_lua_my_log_2 :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    msg := string(lua.L_checkstring(L, 1))
    r0 := my_log_2(msg)
    lua.pushstring(L, strings.clone_to_cstring(r0, context.temp_allocator))
    return 1
}

// Binding odin proc: cg_test_ivec2_echo to lua function: ivec2_echo.
_lua_cg_test_ivec2_echo :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    v := (cast(^ivec2)lua.topointer(L, 1))^
    r0 := cg_test_ivec2_echo(v)
    _lua_push_ffi_ivec2(L, r0)
    return 1
}

// Binding odin proc: cg_test_negate_bool to lua function: negate_bool.
_lua_cg_test_negate_bool :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    b := bool(lua.toboolean(L, 1))
    r0 := cg_test_negate_bool(b)
    lua.pushboolean(L, b32(r0))
    return 1
}

// Binding odin proc: cg_test_zh_add to lua function: zh_add.
_lua_cg_test_zh_add :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    a := f32(lua.L_checknumber(L, 1))
    b := f32(lua.L_checknumber(L, 2))
    r0 := cg_test_zh_add(a, b)
    lua.pushnumber(L, lua.Number(r0))
    return 1
}

// Binding odin proc: world_add_lua to lua function: add.
_lua_world_add_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    name := string(lua.L_checkstring(L, 1))
    model := string(lua.L_checkstring(L, 2))
    position := (cast(^vec3)lua.topointer(L, 3))^
    r0 := world_add_lua(name, model, position)
    lua.pushinteger(L, lua.Integer(transmute(u32)r0))
    return 1
}

// Binding odin proc: entity_set_quat to lua function: set_quat.
_lua_entity_set_quat :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    field := string(lua.L_checkstring(L, 2))
    value := (cast(^quat)lua.topointer(L, 3))^
    entity_set_quat(handle, field, value)
    return 0
}

// Binding odin proc: cg_test_struct_echo to lua function: struct_echo.
_lua_cg_test_struct_echo :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    s := _lua_read_table_Test_Struct(L, 1)
    r0 := cg_test_struct_echo(s)
    _lua_push_table_Test_Struct(L, r0)
    return 1
}

// Binding odin proc: cg_test_entity_m_active_speed to lua function: active_speed.
_lua_cg_test_entity_m_active_speed :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    e := _lua_read_table_Cg_Test_Entity(L, 1)
    r0 := cg_test_entity_m_active_speed(e)
    lua.pushnumber(L, lua.Number(r0))
    return 1
}

// Binding odin proc: cg_test_entity_active_speed to lua function: entity_active_speed.
_lua_cg_test_entity_active_speed :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    e := _lua_read_table_Cg_Test_Entity(L, 1)
    r0 := cg_test_entity_active_speed(e)
    lua.pushnumber(L, lua.Number(r0))
    return 1
}

// Binding odin proc: entity_set_number to lua function: set_number.
_lua_entity_set_number :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    field := string(lua.L_checkstring(L, 2))
    value := f64(lua.L_checknumber(L, 3))
    entity_set_number(handle, field, value)
    return 0
}

// Binding odin proc: entity_set_vec3 to lua function: set_vec3.
_lua_entity_set_vec3 :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    field := string(lua.L_checkstring(L, 2))
    value := (cast(^vec3)lua.topointer(L, 3))^
    entity_set_vec3(handle, field, value)
    return 0
}

// Binding odin proc: cg_test_mat4_echo to lua function: mat4_echo.
_lua_cg_test_mat4_echo :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    v := (cast(^mat4)lua.topointer(L, 1))^
    r0 := cg_test_mat4_echo(v)
    _lua_push_ffi_mat4(L, r0)
    return 1
}

// Binding odin proc: cg_test_add_int to lua function: add_int.
_lua_cg_test_add_int :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    a := int(lua.L_checkinteger(L, 1))
    b := int(lua.L_checkinteger(L, 2))
    r0 := cg_test_add_int(a, b)
    lua.pushinteger(L, lua.Integer(r0))
    return 1
}

// Binding odin proc: entity_get_vec3 to lua function: get_vec3.
_lua_entity_get_vec3 :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    field := string(lua.L_checkstring(L, 2))
    r0 := entity_get_vec3(handle, field)
    _lua_push_ffi_vec3(L, r0)
    return 1
}

// Binding odin proc: cg_test_vec3_echo to lua function: vec3_echo.
_lua_cg_test_vec3_echo :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    v := (cast(^vec3)lua.topointer(L, 1))^
    r0 := cg_test_vec3_echo(v)
    _lua_push_ffi_vec3(L, r0)
    return 1
}

// Binding odin proc: entity_set_string to lua function: set_string.
_lua_entity_set_string :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    field := string(lua.L_checkstring(L, 2))
    value := string(lua.L_checkstring(L, 3))
    entity_set_string(handle, field, value)
    return 0
}

// Binding odin proc: cg_test_ivec2_manhattan to lua function: ivec2_manhattan.
_lua_cg_test_ivec2_manhattan :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    v := (cast(^ivec2)lua.topointer(L, 1))^
    r0 := cg_test_ivec2_manhattan(v)
    lua.pushinteger(L, lua.Integer(r0))
    return 1
}

// Binding odin proc: cg_test_entity_m_pos_lensq to lua function: pos_lensq.
_lua_cg_test_entity_m_pos_lensq :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    e := _lua_read_table_Cg_Test_Entity(L, 1)
    r0 := cg_test_entity_m_pos_lensq(e)
    lua.pushnumber(L, lua.Number(r0))
    return 1
}

// Binding odin proc: cg_test_entity_pos_lensq to lua function: entity_pos_lensq.
_lua_cg_test_entity_pos_lensq :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    e := _lua_read_table_Cg_Test_Entity(L, 1)
    r0 := cg_test_entity_pos_lensq(e)
    lua.pushnumber(L, lua.Number(r0))
    return 1
}

// Binding odin proc: cg_test_add_f32 to lua function: add_f32.
_lua_cg_test_add_f32 :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    a := f32(lua.L_checknumber(L, 1))
    b := f32(lua.L_checknumber(L, 2))
    r0 := cg_test_add_f32(a, b)
    lua.pushnumber(L, lua.Number(r0))
    return 1
}

// Binding odin proc: cg_test_echo_string to lua function: echo_string.
_lua_cg_test_echo_string :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    s := string(lua.L_checkstring(L, 1))
    r0 := cg_test_echo_string(s)
    lua.pushstring(L, strings.clone_to_cstring(r0, context.temp_allocator))
    return 1
}

// Binding odin proc: world_remove_lua to lua function: remove.
_lua_world_remove_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    world_remove_lua(handle)
    return 0
}

// Binding odin proc: entity_get_bool to lua function: get_bool.
_lua_entity_get_bool :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    field := string(lua.L_checkstring(L, 2))
    r0 := entity_get_bool(handle, field)
    lua.pushboolean(L, b32(r0))
    return 1
}

// Binding odin proc: cg_test_vec3_lensq to lua function: vec3_lensq.
_lua_cg_test_vec3_lensq :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    v := (cast(^vec3)lua.topointer(L, 1))^
    r0 := cg_test_vec3_lensq(v)
    lua.pushnumber(L, lua.Number(r0))
    return 1
}

// Binding odin proc: entity_set_bool to lua function: set_bool.
_lua_entity_set_bool :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    field := string(lua.L_checkstring(L, 2))
    value := bool(lua.toboolean(L, 3))
    entity_set_bool(handle, field, value)
    return 0
}

// Binding odin proc: world_find_lua to lua function: find.
_lua_world_find_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    name := string(lua.L_checkstring(L, 1))
    r0, r1 := world_find_lua(name)
    lua.pushinteger(L, lua.Integer(transmute(u32)r0))
    lua.pushboolean(L, b32(r1))
    return 2
}

// Binding odin proc: cg_test_mat3_trace to lua function: mat3_trace.
_lua_cg_test_mat3_trace :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    v := (cast(^mat3)lua.topointer(L, 1))^
    r0 := cg_test_mat3_trace(v)
    lua.pushnumber(L, lua.Number(r0))
    return 1
}

// Binding odin proc: entity_get_string to lua function: get_string.
_lua_entity_get_string :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    field := string(lua.L_checkstring(L, 2))
    r0 := entity_get_string(handle, field)
    lua.pushstring(L, strings.clone_to_cstring(r0, context.temp_allocator))
    return 1
}

// Binding odin proc: cg_test_mat3_echo to lua function: mat3_echo.
_lua_cg_test_mat3_echo :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    v := (cast(^mat3)lua.topointer(L, 1))^
    r0 := cg_test_mat3_echo(v)
    _lua_push_ffi_mat3(L, r0)
    return 1
}

//==================== Register Bindings ====================

_lua_register_all_bindings :: proc(L: ^lua.State) {

    lua.getglobal(L, "Entity")
    if lua.type(L, -1) == .NIL { lua.pop(L, 1); lua.createtable(L, 0, 0) }
    lua.pushcfunction(L, _lua_entity_get_number)
    lua.setfield(L, -2, "get_number")
    lua.pushcfunction(L, _lua_entity_get_number)
    lua.setfield(L, -2, "取数")
    lua.pushcfunction(L, _lua_entity_get_quat)
    lua.setfield(L, -2, "get_quat")
    lua.pushcfunction(L, _lua_entity_get_quat)
    lua.setfield(L, -2, "取四元数")
    lua.pushcfunction(L, _lua_entity_valid)
    lua.setfield(L, -2, "valid")
    lua.pushcfunction(L, _lua_entity_valid)
    lua.setfield(L, -2, "有效")
    lua.pushcfunction(L, _lua_entity_set_quat)
    lua.setfield(L, -2, "set_quat")
    lua.pushcfunction(L, _lua_entity_set_quat)
    lua.setfield(L, -2, "设四元数")
    lua.pushcfunction(L, _lua_entity_set_number)
    lua.setfield(L, -2, "set_number")
    lua.pushcfunction(L, _lua_entity_set_number)
    lua.setfield(L, -2, "设数")
    lua.pushcfunction(L, _lua_entity_set_vec3)
    lua.setfield(L, -2, "set_vec3")
    lua.pushcfunction(L, _lua_entity_set_vec3)
    lua.setfield(L, -2, "设矢量")
    lua.pushcfunction(L, _lua_entity_get_vec3)
    lua.setfield(L, -2, "get_vec3")
    lua.pushcfunction(L, _lua_entity_get_vec3)
    lua.setfield(L, -2, "取矢量")
    lua.pushcfunction(L, _lua_entity_set_string)
    lua.setfield(L, -2, "set_string")
    lua.pushcfunction(L, _lua_entity_set_string)
    lua.setfield(L, -2, "设文本")
    lua.pushcfunction(L, _lua_entity_get_bool)
    lua.setfield(L, -2, "get_bool")
    lua.pushcfunction(L, _lua_entity_get_bool)
    lua.setfield(L, -2, "取布尔")
    lua.pushcfunction(L, _lua_entity_set_bool)
    lua.setfield(L, -2, "set_bool")
    lua.pushcfunction(L, _lua_entity_set_bool)
    lua.setfield(L, -2, "设布尔")
    lua.pushcfunction(L, _lua_entity_get_string)
    lua.setfield(L, -2, "get_string")
    lua.pushcfunction(L, _lua_entity_get_string)
    lua.setfield(L, -2, "取文本")
    lua.setglobal(L, "Entity")

    lua.getglobal(L, "CodegenTest")
    if lua.type(L, -1) == .NIL { lua.pop(L, 1); lua.createtable(L, 0, 0) }
    lua.pushcfunction(L, _lua_cg_test_mat4_trace)
    lua.setfield(L, -2, "mat4_trace")
    lua.pushcfunction(L, _lua_cg_test_entity_echo)
    lua.setfield(L, -2, "entity_echo")
    lua.pushcfunction(L, _lua_cg_test_ivec2_echo)
    lua.setfield(L, -2, "ivec2_echo")
    lua.pushcfunction(L, _lua_cg_test_negate_bool)
    lua.setfield(L, -2, "negate_bool")
    lua.pushcfunction(L, _lua_cg_test_zh_add)
    lua.setfield(L, -2, "zh_add")
    lua.pushcfunction(L, _lua_cg_test_zh_add)
    lua.setfield(L, -2, "相加")
    lua.pushcfunction(L, _lua_cg_test_struct_echo)
    lua.setfield(L, -2, "struct_echo")
    lua.pushcfunction(L, _lua_cg_test_entity_active_speed)
    lua.setfield(L, -2, "entity_active_speed")
    lua.pushcfunction(L, _lua_cg_test_mat4_echo)
    lua.setfield(L, -2, "mat4_echo")
    lua.pushcfunction(L, _lua_cg_test_add_int)
    lua.setfield(L, -2, "add_int")
    lua.pushcfunction(L, _lua_cg_test_vec3_echo)
    lua.setfield(L, -2, "vec3_echo")
    lua.pushcfunction(L, _lua_cg_test_ivec2_manhattan)
    lua.setfield(L, -2, "ivec2_manhattan")
    lua.pushcfunction(L, _lua_cg_test_entity_pos_lensq)
    lua.setfield(L, -2, "entity_pos_lensq")
    lua.pushcfunction(L, _lua_cg_test_add_f32)
    lua.setfield(L, -2, "add_f32")
    lua.pushcfunction(L, _lua_cg_test_echo_string)
    lua.setfield(L, -2, "echo_string")
    lua.pushcfunction(L, _lua_cg_test_vec3_lensq)
    lua.setfield(L, -2, "vec3_lensq")
    lua.pushcfunction(L, _lua_cg_test_mat3_trace)
    lua.setfield(L, -2, "mat3_trace")
    lua.pushcfunction(L, _lua_cg_test_mat3_echo)
    lua.setfield(L, -2, "mat3_echo")
    lua.setglobal(L, "CodegenTest")

    lua.getglobal(L, "Blimp")
    if lua.type(L, -1) == .NIL { lua.pop(L, 1); lua.createtable(L, 0, 0) }
    lua.pushcfunction(L, _lua_my_log)
    lua.setfield(L, -2, "my_log")
    lua.pushcfunction(L, _lua_my_log_2)
    lua.setfield(L, -2, "my_log_2")
    lua.setglobal(L, "Blimp")

    lua.getglobal(L, "World")
    if lua.type(L, -1) == .NIL { lua.pop(L, 1); lua.createtable(L, 0, 0) }
    lua.pushcfunction(L, _lua_world_add_lua)
    lua.setfield(L, -2, "add")
    lua.pushcfunction(L, _lua_world_add_lua)
    lua.setfield(L, -2, "添加")
    lua.pushcfunction(L, _lua_world_remove_lua)
    lua.setfield(L, -2, "remove")
    lua.pushcfunction(L, _lua_world_remove_lua)
    lua.setfield(L, -2, "移除")
    lua.pushcfunction(L, _lua_world_find_lua)
    lua.setfield(L, -2, "find")
    lua.pushcfunction(L, _lua_world_find_lua)
    lua.setfield(L, -2, "查找")
    lua.setglobal(L, "World")

    lua.newtable(L) // __index for Cg_Test_Entity methods
    lua.pushcfunction(L, _lua_cg_test_entity_m_active_speed)
    lua.setfield(L, -2, "active_speed")
    lua.pushcfunction(L, _lua_cg_test_entity_m_pos_lensq)
    lua.setfield(L, -2, "pos_lensq")
    lua.newtable(L)
    lua.pushvalue(L, -2)
    lua.setfield(L, -2, "__index")
    lua.setfield(L, lua.REGISTRYINDEX, "_mt_Cg_Test_Entity")
    lua.pop(L, 1) // pop __index table

}

