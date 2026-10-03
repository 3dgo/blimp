package blimp

import "core:strings"
import sdl "vendor:sdl3"

// Game input, for Lua's Input table: keyboard, mouse and the first gamepad, read from SDL's state once a frame
// (input_update, before the game systems). It's live only while the game has the window: game mode (always in a
// release build; the app passes it in) with the window focused. Otherwise everything reads up and zero, so typing in an
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

input_update :: proc(game_mode: bool) {
    in_ := &input
    in_.keys_prev, in_.mouse_prev, in_.pad_prev = in_.keys, in_.mouse, in_.pad
    in_.live = game_mode && sdl.GetKeyboardFocus() == app.window

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

input_key :: proc(name: string) -> int {
    code := int(sdl.GetScancodeFromName(strings.clone_to_cstring(name, context.temp_allocator)))
    return code > 0 && code < INPUT_MAX_KEYS ? code : -1
}

input_mouse_button :: proc(button: int) -> (sdl.MouseButtonFlag, bool) {
    if button < 1 || button > 5 do return {}, false
    return sdl.MouseButtonFlag(button - 1), true
}

input_pad_button :: proc(name: string) -> (sdl.GamepadButton, bool) {
    b := sdl.GetGamepadButtonFromString(strings.clone_to_cstring(name, context.temp_allocator))
    return b, b != .INVALID
}

