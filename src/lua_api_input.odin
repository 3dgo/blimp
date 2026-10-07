package blimp

import "core:math"
import "core:strings"
import sdl "vendor:sdl3"

// The script API's Input table (输入): the keyboard, mouse and gamepad state input.odin read this frame.
// Thin @(lua) wrappers; nothing here needs a world.

// The key is held. Key names are SDL scancode names: "W", "Space", "Left Shift", "Escape", "Up".
// zh: 这个键现在是否按着。键名是 SDL 扫描码名："W"、"Space"、"Left Shift"、"Escape"、"Up"……
@(lua=down, table=Input, lua_zh="按住")
input_down_lua :: proc(key: string) -> bool {
    k := input_key(key)
    return k >= 0 && input.keys[k]
}

// The key went down this frame (true for that one frame only).
// zh: 这个键是否在这一帧刚按下（只在按下的那一帧为真）。
@(lua=pressed, table=Input, lua_zh="按下")
input_pressed_lua :: proc(key: string) -> bool {
    k := input_key(key)
    return k >= 0 && input.keys[k] && !input.keys_prev[k]
}

// The key went up this frame.
// zh: 这个键是否在这一帧刚松开。
@(lua=released, table=Input, lua_zh="松开")
input_released_lua :: proc(key: string) -> bool {
    k := input_key(key)
    return k >= 0 && !input.keys[k] && input.keys_prev[k]
}

// The mouse button is held: 1 left, 2 middle, 3 right, 4 and 5 the side buttons.
// zh: 鼠标键是否按着：1 左键，2 中键，3 右键，4、5 侧键。
@(lua=mouse_down, table=Input, lua_zh="鼠标按住")
input_mouse_down_lua :: proc(button: int) -> bool {
    b, ok := input_mouse_button(button)
    return ok && b in input.mouse
}

// The mouse button went down this frame: 1 left, 2 middle, 3 right, 4 and 5 the side buttons.
// zh: 鼠标键是否在这一帧刚按下：1 左键，2 中键，3 右键，4、5 侧键。
@(lua=mouse_pressed, table=Input, lua_zh="鼠标按下")
input_mouse_pressed_lua :: proc(button: int) -> bool {
    b, ok := input_mouse_button(button)
    return ok && b in input.mouse && b not_in input.mouse_prev
}

// How far the mouse moved this frame, in pixels (+y down). Works while the mouse is locked too.
// zh: 这一帧鼠标移动的像素（+y 向下）。锁定鼠标时也有效。
@(lua=mouse_delta, table=Input, lua_zh="鼠标移动")
input_mouse_delta_lua :: proc() -> vec2 {
    return input.mouse_delta
}

// Hides the cursor and keeps it in the window, for mouse look. Released while the editor has the window
// (F8 back to it, or Stop), and taken again on return.
// zh: 隐藏光标并锁在窗口里，用于鼠标视角。回到编辑器时（按 F8 或停止）自动放开，回到游戏时重新锁定。
@(lua=lock_mouse, table=Input, lua_zh="锁定鼠标")
input_lock_mouse_lua :: proc(locked: bool) {
    input.mouse_locked = locked
}

// A stick (-1 to 1, +y down, dead zone removed) or trigger (0 to 1) by SDL name: "leftx", "lefty", "rightx",
// "righty", "lefttrigger", "righttrigger". 0 without a gamepad.
// zh: 摇杆（-1 到 1，+y 向下，已去死区）或扳机（0 到 1），用 SDL 名称：
//     "leftx"、"lefty"、"rightx"、"righty"、"lefttrigger"、"righttrigger"。没有手柄时为 0。
@(lua=gamepad_axis, table=Input, lua_zh="手柄轴")
input_gamepad_axis_lua :: proc(axis: string) -> f32 {
    if !input.live || input.gamepad == nil do return 0
    a := sdl.GetGamepadAxisFromString(strings.clone_to_cstring(axis, context.temp_allocator))
    if a == .INVALID do return 0
    v := f32(sdl.GetGamepadAxis(input.gamepad, a)) / 32767
    if abs(v) < GAMEPAD_DEADZONE do return 0
    return math.sign(v) * min((abs(v) - GAMEPAD_DEADZONE) / (1 - GAMEPAD_DEADZONE), 1)
}

// The gamepad button is held, by SDL name: "a", "b", "x", "y", "start", "leftshoulder", "dpup", "leftstick".
// zh: 手柄按键是否按着，用 SDL 名称："a"、"b"、"x"、"y"、"start"、"leftshoulder"、"dpup"、"leftstick"……
@(lua=gamepad_down, table=Input, lua_zh="手柄按住")
input_gamepad_down_lua :: proc(button: string) -> bool {
    b, ok := input_pad_button(button)
    return ok && input.pad[b]
}

// The gamepad button went down this frame (names as Input.gamepad_down).
// zh: 手柄按键是否在这一帧刚按下（名称同 输入.手柄按住）。
@(lua=gamepad_pressed, table=Input, lua_zh="手柄按下")
input_gamepad_pressed_lua :: proc(button: string) -> bool {
    b, ok := input_pad_button(button)
    return ok && input.pad[b] && !input.pad_prev[b]
}
