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

_lua_push_ffi_ivec2 :: proc(L: ^lua.State, v: ivec2) { _lua_push_arr(L, "IVec2", v) }
_lua_read_ffi_ivec2 :: proc(L: ^lua.State, idx: c.int) -> ivec2 {
    p := cast(^ivec2)lua.topointer(L, idx)
    if p == nil { lua.L_argerror(L, idx, "expected IVec2"); return {} }
    return p^
}
_lua_push_ffi_ivec3 :: proc(L: ^lua.State, v: ivec3) { _lua_push_arr(L, "IVec3", v) }
_lua_read_ffi_ivec3 :: proc(L: ^lua.State, idx: c.int) -> ivec3 {
    p := cast(^ivec3)lua.topointer(L, idx)
    if p == nil { lua.L_argerror(L, idx, "expected IVec3"); return {} }
    return p^
}
_lua_push_ffi_ivec4 :: proc(L: ^lua.State, v: ivec4) { _lua_push_arr(L, "IVec4", v) }
_lua_read_ffi_ivec4 :: proc(L: ^lua.State, idx: c.int) -> ivec4 {
    p := cast(^ivec4)lua.topointer(L, idx)
    if p == nil { lua.L_argerror(L, idx, "expected IVec4"); return {} }
    return p^
}
_lua_push_ffi_mat3 :: proc(L: ^lua.State, v: mat3) { _lua_push_arr(L, "Mat3", transmute([9]f32)v) }
_lua_read_ffi_mat3 :: proc(L: ^lua.State, idx: c.int) -> mat3 {
    p := cast(^mat3)lua.topointer(L, idx)
    if p == nil { lua.L_argerror(L, idx, "expected Mat3"); return {} }
    return p^
}
_lua_push_ffi_mat4 :: proc(L: ^lua.State, v: mat4) { _lua_push_arr(L, "Mat4", transmute([16]f32)v) }
_lua_read_ffi_mat4 :: proc(L: ^lua.State, idx: c.int) -> mat4 {
    p := cast(^mat4)lua.topointer(L, idx)
    if p == nil { lua.L_argerror(L, idx, "expected Mat4"); return {} }
    return p^
}
_lua_push_ffi_quat :: proc(L: ^lua.State, v: quat) { _lua_push_arr(L, "Quat", transmute([4]f32)v) }
_lua_read_ffi_quat :: proc(L: ^lua.State, idx: c.int) -> quat {
    p := cast(^quat)lua.topointer(L, idx)
    if p == nil { lua.L_argerror(L, idx, "expected Quat"); return {} }
    return p^
}
_lua_push_ffi_vec2 :: proc(L: ^lua.State, v: vec2) { _lua_push_arr(L, "Vec2", v) }
_lua_read_ffi_vec2 :: proc(L: ^lua.State, idx: c.int) -> vec2 {
    p := cast(^vec2)lua.topointer(L, idx)
    if p == nil { lua.L_argerror(L, idx, "expected Vec2"); return {} }
    return p^
}
_lua_push_ffi_vec3 :: proc(L: ^lua.State, v: vec3) { _lua_push_arr(L, "Vec3", v) }
_lua_read_ffi_vec3 :: proc(L: ^lua.State, idx: c.int) -> vec3 {
    p := cast(^vec3)lua.topointer(L, idx)
    if p == nil { lua.L_argerror(L, idx, "expected Vec3"); return {} }
    return p^
}
_lua_push_ffi_vec4 :: proc(L: ^lua.State, v: vec4) { _lua_push_arr(L, "Vec4", v) }
_lua_read_ffi_vec4 :: proc(L: ^lua.State, idx: c.int) -> vec4 {
    p := cast(^vec4)lua.topointer(L, idx)
    if p == nil { lua.L_argerror(L, idx, "expected Vec4"); return {} }
    return p^
}

//==================== Generate Procs ====================

// Binding odin proc: entity_get_bool to lua function: get_bool.
_lua_entity_get_bool :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    field := string(lua.L_checkstring(L, 2))
    r0 := entity_get_bool(handle, field)
    lua.pushboolean(L, b32(r0))
    return 1
}

// Binding odin proc: entity_get_number to lua function: get_number.
_lua_entity_get_number :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    field := string(lua.L_checkstring(L, 2))
    r0 := entity_get_number(handle, field)
    lua.pushnumber(L, lua.Number(r0))
    return 1
}

// Binding odin proc: entity_get_position to lua function: get_position.
_lua_entity_get_position :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    r0 := entity_get_position(handle)
    _lua_push_ffi_vec3(L, r0)
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

// Binding odin proc: entity_get_rotation to lua function: get_rotation.
_lua_entity_get_rotation :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    r0 := entity_get_rotation(handle)
    _lua_push_ffi_quat(L, r0)
    return 1
}

// Binding odin proc: entity_get_scale to lua function: get_scale.
_lua_entity_get_scale :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    r0 := entity_get_scale(handle)
    _lua_push_ffi_vec3(L, r0)
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

// Binding odin proc: entity_get_vec3 to lua function: get_vec3.
_lua_entity_get_vec3 :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    field := string(lua.L_checkstring(L, 2))
    r0 := entity_get_vec3(handle, field)
    _lua_push_ffi_vec3(L, r0)
    return 1
}

// Binding odin proc: entity_hide to lua function: hide.
_lua_entity_hide :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    entity_hide(handle)
    return 0
}

// Binding odin proc: entity_is_hidden to lua function: is_hidden.
_lua_entity_is_hidden :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    r0 := entity_is_hidden(handle)
    lua.pushboolean(L, b32(r0))
    return 1
}

// Binding odin proc: entity_move_character_lua to lua function: move_character.
_lua_entity_move_character_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    delta := _lua_read_ffi_vec3(L, 2)
    radius := f32(lua.L_checknumber(L, 3))
    height := f32(lua.L_checknumber(L, 4))
    r0 := entity_move_character_lua(handle, delta, radius, height)
    lua.pushboolean(L, b32(r0))
    return 1
}

// Binding odin proc: entity_play_sound_lua to lua function: play_sound.
_lua_entity_play_sound_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    r0 := entity_play_sound_lua(handle)
    lua.pushboolean(L, b32(r0))
    return 1
}

// Binding odin proc: entity_rotate to lua function: rotate.
_lua_entity_rotate :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    by := _lua_read_ffi_quat(L, 2)
    entity_rotate(handle, by)
    return 0
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

// Binding odin proc: entity_set_number to lua function: set_number.
_lua_entity_set_number :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    field := string(lua.L_checkstring(L, 2))
    value := f64(lua.L_checknumber(L, 3))
    entity_set_number(handle, field, value)
    return 0
}

// Binding odin proc: entity_set_position to lua function: set_position.
_lua_entity_set_position :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    position := _lua_read_ffi_vec3(L, 2)
    entity_set_position(handle, position)
    return 0
}

// Binding odin proc: entity_set_quat to lua function: set_quat.
_lua_entity_set_quat :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    field := string(lua.L_checkstring(L, 2))
    value := _lua_read_ffi_quat(L, 3)
    entity_set_quat(handle, field, value)
    return 0
}

// Binding odin proc: entity_set_rotation to lua function: set_rotation.
_lua_entity_set_rotation :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    rotation := _lua_read_ffi_quat(L, 2)
    entity_set_rotation(handle, rotation)
    return 0
}

// Binding odin proc: entity_set_scale to lua function: set_scale.
_lua_entity_set_scale :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    scale := _lua_read_ffi_vec3(L, 2)
    entity_set_scale(handle, scale)
    return 0
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

// Binding odin proc: entity_set_vec3 to lua function: set_vec3.
_lua_entity_set_vec3 :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    field := string(lua.L_checkstring(L, 2))
    value := _lua_read_ffi_vec3(L, 3)
    entity_set_vec3(handle, field, value)
    return 0
}

// Binding odin proc: entity_stop_sound_lua to lua function: stop_sound.
_lua_entity_stop_sound_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    entity_stop_sound_lua(handle)
    return 0
}

// Binding odin proc: entity_translate to lua function: translate.
_lua_entity_translate :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    delta := _lua_read_ffi_vec3(L, 2)
    entity_translate(handle, delta)
    return 0
}

// Binding odin proc: entity_unhide to lua function: unhide.
_lua_entity_unhide :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    entity_unhide(handle)
    return 0
}

// Binding odin proc: entity_valid to lua function: valid.
_lua_entity_valid :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    r0 := entity_valid(handle)
    lua.pushboolean(L, b32(r0))
    return 1
}

// Binding odin proc: input_down_lua to lua function: down.
_lua_input_down_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    key := string(lua.L_checkstring(L, 1))
    r0 := input_down_lua(key)
    lua.pushboolean(L, b32(r0))
    return 1
}

// Binding odin proc: input_gamepad_axis_lua to lua function: gamepad_axis.
_lua_input_gamepad_axis_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    axis := string(lua.L_checkstring(L, 1))
    r0 := input_gamepad_axis_lua(axis)
    lua.pushnumber(L, lua.Number(r0))
    return 1
}

// Binding odin proc: input_gamepad_down_lua to lua function: gamepad_down.
_lua_input_gamepad_down_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    button := string(lua.L_checkstring(L, 1))
    r0 := input_gamepad_down_lua(button)
    lua.pushboolean(L, b32(r0))
    return 1
}

// Binding odin proc: input_gamepad_pressed_lua to lua function: gamepad_pressed.
_lua_input_gamepad_pressed_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    button := string(lua.L_checkstring(L, 1))
    r0 := input_gamepad_pressed_lua(button)
    lua.pushboolean(L, b32(r0))
    return 1
}

// Binding odin proc: input_lock_mouse_lua to lua function: lock_mouse.
_lua_input_lock_mouse_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    locked := bool(lua.toboolean(L, 1))
    input_lock_mouse_lua(locked)
    return 0
}

// Binding odin proc: input_mouse_delta_lua to lua function: mouse_delta.
_lua_input_mouse_delta_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    r0 := input_mouse_delta_lua()
    _lua_push_ffi_vec2(L, r0)
    return 1
}

// Binding odin proc: input_mouse_down_lua to lua function: mouse_down.
_lua_input_mouse_down_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    button := int(lua.L_checkinteger(L, 1))
    r0 := input_mouse_down_lua(button)
    lua.pushboolean(L, b32(r0))
    return 1
}

// Binding odin proc: input_mouse_pressed_lua to lua function: mouse_pressed.
_lua_input_mouse_pressed_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    button := int(lua.L_checkinteger(L, 1))
    r0 := input_mouse_pressed_lua(button)
    lua.pushboolean(L, b32(r0))
    return 1
}

// Binding odin proc: input_pressed_lua to lua function: pressed.
_lua_input_pressed_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    key := string(lua.L_checkstring(L, 1))
    r0 := input_pressed_lua(key)
    lua.pushboolean(L, b32(r0))
    return 1
}

// Binding odin proc: input_released_lua to lua function: released.
_lua_input_released_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    key := string(lua.L_checkstring(L, 1))
    r0 := input_released_lua(key)
    lua.pushboolean(L, b32(r0))
    return 1
}

// Binding odin proc: world_add_lua to lua function: add.
_lua_world_add_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    name := string(lua.L_checkstring(L, 1))
    model := string(lua.L_checkstring(L, 2))
    position: vec3 = {0, 0, 0}
    if !lua.isnoneornil(L, 3) do position = _lua_read_ffi_vec3(L, 3)
    r0 := world_add_lua(name, model, position)
    lua.pushinteger(L, lua.Integer(transmute(u32)r0))
    return 1
}

// Binding odin proc: world_debug_line_lua to lua function: debug_line.
_lua_world_debug_line_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    from := _lua_read_ffi_vec3(L, 1)
    to := _lua_read_ffi_vec3(L, 2)
    color: vec4 = {1, 1, 1, 1}
    if !lua.isnoneornil(L, 3) do color = _lua_read_ffi_vec4(L, 3)
    world_debug_line_lua(from, to, color)
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

// Binding odin proc: world_get_lua to lua function: get.
_lua_world_get_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    name := string(lua.L_checkstring(L, 1))
    r0 := world_get_lua(name)
    lua.pushinteger(L, lua.Integer(transmute(u32)r0))
    return 1
}

// Binding odin proc: world_light_group_lua to lua function: light_group.
_lua_world_light_group_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    name := string(lua.L_checkstring(L, 1))
    r0 := world_light_group_lua(name)
    lua.pushnumber(L, lua.Number(r0))
    return 1
}

// Binding odin proc: world_play_sound_at_lua to lua function: play_sound_at.
_lua_world_play_sound_at_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    key := string(lua.L_checkstring(L, 1))
    position := _lua_read_ffi_vec3(L, 2)
    volume := f32(lua.L_optnumber(L, 3, 1))
    r0 := world_play_sound_at_lua(key, position, volume)
    lua.pushboolean(L, b32(r0))
    return 1
}

// Binding odin proc: world_play_sound_lua to lua function: play_sound.
_lua_world_play_sound_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    key := string(lua.L_checkstring(L, 1))
    volume := f32(lua.L_optnumber(L, 2, 1))
    r0 := world_play_sound_lua(key, volume)
    lua.pushboolean(L, b32(r0))
    return 1
}

// Binding odin proc: world_raycast_lua to lua function: raycast.
_lua_world_raycast_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    origin := _lua_read_ffi_vec3(L, 1)
    direction := _lua_read_ffi_vec3(L, 2)
    distance := f32(lua.L_checknumber(L, 3))
    r0, r1, r2, r3 := world_raycast_lua(origin, direction, distance)
    lua.pushboolean(L, b32(r0))
    _lua_push_ffi_vec3(L, r1)
    _lua_push_ffi_vec3(L, r2)
    lua.pushinteger(L, lua.Integer(transmute(u32)r3))
    return 4
}

// Binding odin proc: world_remove_lua to lua function: remove.
_lua_world_remove_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    handle := transmute(Entity_Handle)u32(lua.L_checkinteger(L, 1))
    world_remove_lua(handle)
    return 0
}

// Binding odin proc: world_set_light_group_lua to lua function: set_light_group.
_lua_world_set_light_group_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    name := string(lua.L_checkstring(L, 1))
    scale := f32(lua.L_checknumber(L, 2))
    r0 := world_set_light_group_lua(name, scale)
    lua.pushboolean(L, b32(r0))
    return 1
}

// Binding odin proc: world_time_lua to lua function: time.
_lua_world_time_lua :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    r0 := world_time_lua()
    lua.pushnumber(L, lua.Number(r0))
    return 1
}

//==================== Register Bindings ====================

_lua_register_all_bindings :: proc(L: ^lua.State) {

    lua.getglobal(L, "Entity")
    if lua.type(L, -1) == .NIL { lua.pop(L, 1); lua.createtable(L, 0, 0) }
    lua.pushcfunction(L, _lua_entity_get_bool)
    lua.setfield(L, -2, "get_bool")
    lua.pushcfunction(L, _lua_entity_get_bool)
    lua.setfield(L, -2, "取布尔")
    lua.pushcfunction(L, _lua_entity_get_number)
    lua.setfield(L, -2, "get_number")
    lua.pushcfunction(L, _lua_entity_get_number)
    lua.setfield(L, -2, "取数")
    lua.pushcfunction(L, _lua_entity_get_position)
    lua.setfield(L, -2, "get_position")
    lua.pushcfunction(L, _lua_entity_get_position)
    lua.setfield(L, -2, "取位置")
    lua.pushcfunction(L, _lua_entity_get_quat)
    lua.setfield(L, -2, "get_quat")
    lua.pushcfunction(L, _lua_entity_get_quat)
    lua.setfield(L, -2, "取四元数")
    lua.pushcfunction(L, _lua_entity_get_rotation)
    lua.setfield(L, -2, "get_rotation")
    lua.pushcfunction(L, _lua_entity_get_rotation)
    lua.setfield(L, -2, "取朝向")
    lua.pushcfunction(L, _lua_entity_get_scale)
    lua.setfield(L, -2, "get_scale")
    lua.pushcfunction(L, _lua_entity_get_scale)
    lua.setfield(L, -2, "取缩放")
    lua.pushcfunction(L, _lua_entity_get_string)
    lua.setfield(L, -2, "get_string")
    lua.pushcfunction(L, _lua_entity_get_string)
    lua.setfield(L, -2, "取文本")
    lua.pushcfunction(L, _lua_entity_get_vec3)
    lua.setfield(L, -2, "get_vec3")
    lua.pushcfunction(L, _lua_entity_get_vec3)
    lua.setfield(L, -2, "取矢量")
    lua.pushcfunction(L, _lua_entity_hide)
    lua.setfield(L, -2, "hide")
    lua.pushcfunction(L, _lua_entity_hide)
    lua.setfield(L, -2, "隐藏")
    lua.pushcfunction(L, _lua_entity_is_hidden)
    lua.setfield(L, -2, "is_hidden")
    lua.pushcfunction(L, _lua_entity_is_hidden)
    lua.setfield(L, -2, "是否隐藏")
    lua.pushcfunction(L, _lua_entity_move_character_lua)
    lua.setfield(L, -2, "move_character")
    lua.pushcfunction(L, _lua_entity_move_character_lua)
    lua.setfield(L, -2, "角色移动")
    lua.pushcfunction(L, _lua_entity_play_sound_lua)
    lua.setfield(L, -2, "play_sound")
    lua.pushcfunction(L, _lua_entity_play_sound_lua)
    lua.setfield(L, -2, "播放声音")
    lua.pushcfunction(L, _lua_entity_rotate)
    lua.setfield(L, -2, "rotate")
    lua.pushcfunction(L, _lua_entity_rotate)
    lua.setfield(L, -2, "旋转")
    lua.pushcfunction(L, _lua_entity_set_bool)
    lua.setfield(L, -2, "set_bool")
    lua.pushcfunction(L, _lua_entity_set_bool)
    lua.setfield(L, -2, "设布尔")
    lua.pushcfunction(L, _lua_entity_set_number)
    lua.setfield(L, -2, "set_number")
    lua.pushcfunction(L, _lua_entity_set_number)
    lua.setfield(L, -2, "设数")
    lua.pushcfunction(L, _lua_entity_set_position)
    lua.setfield(L, -2, "set_position")
    lua.pushcfunction(L, _lua_entity_set_position)
    lua.setfield(L, -2, "设位置")
    lua.pushcfunction(L, _lua_entity_set_quat)
    lua.setfield(L, -2, "set_quat")
    lua.pushcfunction(L, _lua_entity_set_quat)
    lua.setfield(L, -2, "设四元数")
    lua.pushcfunction(L, _lua_entity_set_rotation)
    lua.setfield(L, -2, "set_rotation")
    lua.pushcfunction(L, _lua_entity_set_rotation)
    lua.setfield(L, -2, "设朝向")
    lua.pushcfunction(L, _lua_entity_set_scale)
    lua.setfield(L, -2, "set_scale")
    lua.pushcfunction(L, _lua_entity_set_scale)
    lua.setfield(L, -2, "设缩放")
    lua.pushcfunction(L, _lua_entity_set_string)
    lua.setfield(L, -2, "set_string")
    lua.pushcfunction(L, _lua_entity_set_string)
    lua.setfield(L, -2, "设文本")
    lua.pushcfunction(L, _lua_entity_set_vec3)
    lua.setfield(L, -2, "set_vec3")
    lua.pushcfunction(L, _lua_entity_set_vec3)
    lua.setfield(L, -2, "设矢量")
    lua.pushcfunction(L, _lua_entity_stop_sound_lua)
    lua.setfield(L, -2, "stop_sound")
    lua.pushcfunction(L, _lua_entity_stop_sound_lua)
    lua.setfield(L, -2, "停止声音")
    lua.pushcfunction(L, _lua_entity_translate)
    lua.setfield(L, -2, "translate")
    lua.pushcfunction(L, _lua_entity_translate)
    lua.setfield(L, -2, "平移")
    lua.pushcfunction(L, _lua_entity_unhide)
    lua.setfield(L, -2, "unhide")
    lua.pushcfunction(L, _lua_entity_unhide)
    lua.setfield(L, -2, "取消隐藏")
    lua.pushcfunction(L, _lua_entity_valid)
    lua.setfield(L, -2, "valid")
    lua.pushcfunction(L, _lua_entity_valid)
    lua.setfield(L, -2, "有效")
    lua.setglobal(L, "Entity")

    lua.getglobal(L, "Input")
    if lua.type(L, -1) == .NIL { lua.pop(L, 1); lua.createtable(L, 0, 0) }
    lua.pushcfunction(L, _lua_input_down_lua)
    lua.setfield(L, -2, "down")
    lua.pushcfunction(L, _lua_input_down_lua)
    lua.setfield(L, -2, "按住")
    lua.pushcfunction(L, _lua_input_gamepad_axis_lua)
    lua.setfield(L, -2, "gamepad_axis")
    lua.pushcfunction(L, _lua_input_gamepad_axis_lua)
    lua.setfield(L, -2, "手柄轴")
    lua.pushcfunction(L, _lua_input_gamepad_down_lua)
    lua.setfield(L, -2, "gamepad_down")
    lua.pushcfunction(L, _lua_input_gamepad_down_lua)
    lua.setfield(L, -2, "手柄按住")
    lua.pushcfunction(L, _lua_input_gamepad_pressed_lua)
    lua.setfield(L, -2, "gamepad_pressed")
    lua.pushcfunction(L, _lua_input_gamepad_pressed_lua)
    lua.setfield(L, -2, "手柄按下")
    lua.pushcfunction(L, _lua_input_lock_mouse_lua)
    lua.setfield(L, -2, "lock_mouse")
    lua.pushcfunction(L, _lua_input_lock_mouse_lua)
    lua.setfield(L, -2, "锁定鼠标")
    lua.pushcfunction(L, _lua_input_mouse_delta_lua)
    lua.setfield(L, -2, "mouse_delta")
    lua.pushcfunction(L, _lua_input_mouse_delta_lua)
    lua.setfield(L, -2, "鼠标移动")
    lua.pushcfunction(L, _lua_input_mouse_down_lua)
    lua.setfield(L, -2, "mouse_down")
    lua.pushcfunction(L, _lua_input_mouse_down_lua)
    lua.setfield(L, -2, "鼠标按住")
    lua.pushcfunction(L, _lua_input_mouse_pressed_lua)
    lua.setfield(L, -2, "mouse_pressed")
    lua.pushcfunction(L, _lua_input_mouse_pressed_lua)
    lua.setfield(L, -2, "鼠标按下")
    lua.pushcfunction(L, _lua_input_pressed_lua)
    lua.setfield(L, -2, "pressed")
    lua.pushcfunction(L, _lua_input_pressed_lua)
    lua.setfield(L, -2, "按下")
    lua.pushcfunction(L, _lua_input_released_lua)
    lua.setfield(L, -2, "released")
    lua.pushcfunction(L, _lua_input_released_lua)
    lua.setfield(L, -2, "松开")
    lua.setglobal(L, "Input")

    lua.getglobal(L, "World")
    if lua.type(L, -1) == .NIL { lua.pop(L, 1); lua.createtable(L, 0, 0) }
    lua.pushcfunction(L, _lua_world_add_lua)
    lua.setfield(L, -2, "add")
    lua.pushcfunction(L, _lua_world_add_lua)
    lua.setfield(L, -2, "添加")
    lua.pushcfunction(L, _lua_world_debug_line_lua)
    lua.setfield(L, -2, "debug_line")
    lua.pushcfunction(L, _lua_world_debug_line_lua)
    lua.setfield(L, -2, "调试线")
    lua.pushcfunction(L, _lua_world_find_lua)
    lua.setfield(L, -2, "find")
    lua.pushcfunction(L, _lua_world_find_lua)
    lua.setfield(L, -2, "查找")
    lua.pushcfunction(L, _lua_world_get_lua)
    lua.setfield(L, -2, "get")
    lua.pushcfunction(L, _lua_world_get_lua)
    lua.setfield(L, -2, "获取")
    lua.pushcfunction(L, _lua_world_light_group_lua)
    lua.setfield(L, -2, "light_group")
    lua.pushcfunction(L, _lua_world_light_group_lua)
    lua.setfield(L, -2, "光源组")
    lua.pushcfunction(L, _lua_world_play_sound_at_lua)
    lua.setfield(L, -2, "play_sound_at")
    lua.pushcfunction(L, _lua_world_play_sound_at_lua)
    lua.setfield(L, -2, "在位置播放声音")
    lua.pushcfunction(L, _lua_world_play_sound_lua)
    lua.setfield(L, -2, "play_sound")
    lua.pushcfunction(L, _lua_world_play_sound_lua)
    lua.setfield(L, -2, "播放声音")
    lua.pushcfunction(L, _lua_world_raycast_lua)
    lua.setfield(L, -2, "raycast")
    lua.pushcfunction(L, _lua_world_raycast_lua)
    lua.setfield(L, -2, "射线检测")
    lua.pushcfunction(L, _lua_world_remove_lua)
    lua.setfield(L, -2, "remove")
    lua.pushcfunction(L, _lua_world_remove_lua)
    lua.setfield(L, -2, "移除")
    lua.pushcfunction(L, _lua_world_set_light_group_lua)
    lua.setfield(L, -2, "set_light_group")
    lua.pushcfunction(L, _lua_world_set_light_group_lua)
    lua.setfield(L, -2, "设光源组")
    lua.pushcfunction(L, _lua_world_time_lua)
    lua.setfield(L, -2, "time")
    lua.pushcfunction(L, _lua_world_time_lua)
    lua.setfield(L, -2, "时间")
    lua.setglobal(L, "World")

}

