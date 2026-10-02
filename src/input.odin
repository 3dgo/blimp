package blimp

import "core:math"
import "core:strings"
import sdl "vendor:sdl3"

// Game input, for Lua's Input table: keyboard, mouse and the first gamepad, read from SDL's state once a frame
// (input_update, before the game systems). It's live only while the game has the window: game mode (ui.game,
// always in a release build) with the window focused. Otherwise everything reads up and zero, so typing in an
// editor panel never moves the player. Pressed / released compare with the previous frame.
//
// Keys are SDL scancode names, any case: "W", "Space", "Left Shift", "Escape", "Up", "1". Mouse buttons are
// 1 left, 2 middle, 3 right, 4–5 the side ones. Gamepad buttons and axes are SDL's names: "a" "b" "x" "y"
// "start" "back" "leftshoulder" "dpup"…, and "leftx" "lefty" "rightx" "righty" "lefttrigger" "righttrigger".

INPUT_MAX_KEYS      :: 512
GAMEPAD_DEADZONE    :: 0.15   // stick travel (0–1) read as centred

Input :: struct {
    live:              bool,
    keys, keys_prev:   [INPUT_MAX_KEYS]bool,
    mouse, mouse_prev: sdl.MouseButtonFlags,
    mouse_delta:       vec2,
    mouse_locked:      bool,   // asked for by the game (Input.lock_mouse); applied only while live
    gamepad:           ^sdl.Gamepad,
    pad, pad_prev:     [sdl.GamepadButton]bool,
}
input: Input

input_update :: proc() {
    in_ := &input
    in_.keys_prev, in_.mouse_prev, in_.pad_prev = in_.keys, in_.mouse, in_.pad
    in_.live = ui.game != nil && sdl.GetKeyboardFocus() == app.window

    // Always read, so the relative motion doesn't pile up while the editor has the mouse.
    dx, dy: f32
    _ = sdl.GetRelativeMouseState(&dx, &dy)
    want_lock := in_.live && in_.mouse_locked
    if want_lock != sdl.GetWindowRelativeMouseMode(app.window) do _ = sdl.SetWindowRelativeMouseMode(app.window, want_lock)

    if in_.gamepad != nil && !sdl.GamepadConnected(in_.gamepad) {
        sdl.CloseGamepad(in_.gamepad)
        in_.gamepad = nil
    }
    if in_.gamepad == nil {
        count: i32
        if ids := sdl.GetGamepads(&count); ids != nil {
            if count > 0 do in_.gamepad = sdl.OpenGamepad(ids[0])
            sdl.free(ids)
        }
    }

    if !in_.live {
        in_.keys, in_.mouse, in_.pad, in_.mouse_delta = {}, {}, {}, {}
        return
    }
    n: i32
    state := sdl.GetKeyboardState(&n)
    for i in 0..<min(int(n), INPUT_MAX_KEYS) do in_.keys[i] = state[i]
    in_.mouse = sdl.GetMouseState(nil, nil)
    in_.mouse_delta = {dx, dy}
    for b in sdl.GamepadButton {
        if b == .INVALID do continue
        in_.pad[b] = in_.gamepad != nil && sdl.GetGamepadButton(in_.gamepad, b)
    }
}

input_shutdown :: proc() {
    if input.gamepad != nil do sdl.CloseGamepad(input.gamepad)
    input.gamepad = nil
}

@(private="file")
input_key :: proc(name: string) -> int {
    code := int(sdl.GetScancodeFromName(strings.clone_to_cstring(name, context.temp_allocator)))
    return code > 0 && code < INPUT_MAX_KEYS ? code : -1
}

@(private="file")
input_mouse_button :: proc(button: int) -> (sdl.MouseButtonFlag, bool) {
    if button < 1 || button > 5 do return {}, false
    return sdl.MouseButtonFlag(button - 1), true
}

@(private="file")
input_pad_button :: proc(name: string) -> (sdl.GamepadButton, bool) {
    b := sdl.GetGamepadButtonFromString(strings.clone_to_cstring(name, context.temp_allocator))
    return b, b != .INVALID
}

// ============================ Lua ============================

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
