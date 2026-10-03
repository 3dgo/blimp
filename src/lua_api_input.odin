package blimp

import "core:math"
import "core:strings"
import sdl "vendor:sdl3"

// The script API's Input table (输入): the keyboard, mouse and gamepad state input.odin read this frame.
// Thin @(lua) wrappers; nothing here needs a world.

@(lua=down, table=Input, lua_zh="按住")
input_down_lua :: proc(key: string) -> bool {
    k := input_key(key)
    return k >= 0 && input.keys[k]
}

@(lua=pressed, table=Input, lua_zh="按下")
input_pressed_lua :: proc(key: string) -> bool {
    k := input_key(key)
    return k >= 0 && input.keys[k] && !input.keys_prev[k]
}

@(lua=released, table=Input, lua_zh="松开")
input_released_lua :: proc(key: string) -> bool {
    k := input_key(key)
    return k >= 0 && !input.keys[k] && input.keys_prev[k]
}

@(lua=mouse_down, table=Input, lua_zh="鼠标按住")
input_mouse_down_lua :: proc(button: int) -> bool {
    b, ok := input_mouse_button(button)
    return ok && b in input.mouse
}

@(lua=mouse_pressed, table=Input, lua_zh="鼠标按下")
input_mouse_pressed_lua :: proc(button: int) -> bool {
    b, ok := input_mouse_button(button)
    return ok && b in input.mouse && b not_in input.mouse_prev
}

// How far the mouse moved this frame, in pixels (+y down). Works while the mouse is locked too.
@(lua=mouse_delta, table=Input, lua_zh="鼠标移动")
input_mouse_delta_lua :: proc() -> vec2 {
    return input.mouse_delta
}

// Hides the cursor and keeps it in the window, for mouse look. Released while the editor has the window
// (F8 back to it, or Stop), and taken again on return.
@(lua=lock_mouse, table=Input, lua_zh="锁定鼠标")
input_lock_mouse_lua :: proc(locked: bool) {
    input.mouse_locked = locked
}

// A stick (−1 to 1, +y down, centred inside GAMEPAD_DEADZONE) or trigger (0 to 1). 0 without a gamepad.
@(lua=gamepad_axis, table=Input, lua_zh="手柄轴")
input_gamepad_axis_lua :: proc(axis: string) -> f32 {
    if !input.live || input.gamepad == nil do return 0
    a := sdl.GetGamepadAxisFromString(strings.clone_to_cstring(axis, context.temp_allocator))
    if a == .INVALID do return 0
    v := f32(sdl.GetGamepadAxis(input.gamepad, a)) / 32767
    if abs(v) < GAMEPAD_DEADZONE do return 0
    return math.sign(v) * min((abs(v) - GAMEPAD_DEADZONE) / (1 - GAMEPAD_DEADZONE), 1)
}

@(lua=gamepad_down, table=Input, lua_zh="手柄按住")
input_gamepad_down_lua :: proc(button: string) -> bool {
    b, ok := input_pad_button(button)
    return ok && input.pad[b]
}

@(lua=gamepad_pressed, table=Input, lua_zh="手柄按下")
input_gamepad_pressed_lua :: proc(button: string) -> bool {
    b, ok := input_pad_button(button)
    return ok && input.pad[b] && !input.pad_prev[b]
}
