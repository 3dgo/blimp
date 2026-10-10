package blimp

import "core:fmt"
import "core:log"
import im "lib:odin-imgui"

// The script API's UI table (界面): the game's screen UI, drawn with Dear ImGui by a world script's ui hook
// (function World.ui() / 世界.界面()). The UI layer calls that hook for every view showing a play world, every
// frame, paused or not (ui_view_game_ui), and these procs work only inside it. It's the one place the script API
// reaches up into the UI layer (CLAUDE.md); world code still knows nothing about it.
//
// Immediate mode keeps Lua stateless: ImGui remembers hover and drags by label, and a value a widget edits comes in
// from Odin (Game, an entity field) and goes back there. Positions and sizes are fractions of the view, so the UI
// lands in the same place at any window size. The engine opens and closes everything around the hook, so a script
// error part way through a window can't unbalance ImGui.

@(private="file")
lua_ui: struct {
    active:  bool,      // inside a ui hook
    lo, hi:  im.Vec2,   // the view's image on screen
    windows: int,       // windows open (UI.begin_window); the engine closes what the script left open
    warned:  u64,       // frame of the last misuse error, so a mistake logs once a frame, not per call
}

// The world's ui hook over the view image just drawn at lo..hi.
ui_view_game_ui :: proc(view: ^Render_View, lo, hi: im.Vec2) {
    if view.world.play_source == nil do return
    lua_ui.active, lua_ui.lo, lua_ui.hi, lua_ui.windows = true, lo, hi, 0
    lua_world_ui(view.world)
    for lua_ui.windows > 0 do ui_lua_window_close()   // left open by the script, or by an error part way
    lua_ui.active = false
    im.SetCursorScreenPos(lo)   // back inside the view: ImGui asserts on a window grown by a cursor move alone
    im.Dummy({0, 0})
}

@(private="file")
ui_lua_ready :: proc(loc := #caller_location) -> bool {
    if lua_ui.active do return true
    ui_lua_error("Lua: %s draws UI; call it from the world script's ui hook (World.ui / 世界.界面)", loc.procedure)
    return false
}

@(private="file")
ui_lua_error :: proc(format: string, args: ..any) {
    if lua_ui.warned == timer_frame_index() do return
    lua_ui.warned = timer_frame_index()
    log.errorf(format, ..args)
}

// A point in the view, from fractions of it.
@(private="file")
ui_lua_point :: proc(x, y: f32) -> im.Vec2 { return lua_ui.lo + (lua_ui.hi - lua_ui.lo) * im.Vec2{x, y} }

@(private="file")
ui_lua_window_close :: proc() {
    im.EndChild()
    lua_ui.windows -= 1
}

/* --------------------------------- Layout --------------------------------- */

// Where the next text or widget goes: its top-left at (x, y), fractions of the view from its top-left (0.5, 0.5 is
// the centre). For UI over the scene; inside a window, widgets flow top to bottom on their own.
// zh: 下一个文字或控件放在哪里：它的左上角在 (x, y)，按视口宽高的比例从左上角算（0.5, 0.5 是正中）。用于直接画在画面上的界面；
//     窗口里的控件自己从上往下排。
@(lua=position, table=UI, lua_zh="位置")
ui_lua_position :: proc(x: f32, y: f32) {
    if ui_lua_ready() do im.SetCursorScreenPos(ui_lua_point(x, y))
}

// The next text or widget goes to the right of the last one instead of below it.
// zh: 下一个文字或控件放在上一个的右边，而不是下面。
@(lua=same_line, table=UI, lua_zh="同一行")
ui_lua_same_line :: proc() {
    if ui_lua_ready() do im.SameLine()
}

// A horizontal rule.
// zh: 一条横线。
@(lua=separator, table=UI, lua_zh="分隔线")
ui_lua_separator :: proc() {
    if ui_lua_ready() do im.Separator()
}

// A little vertical space.
// zh: 一点竖直的空白。
@(lua=spacing, table=UI, lua_zh="间距")
ui_lua_spacing :: proc() {
    if ui_lua_ready() do im.Spacing()
}

/* --------------------------------- Display -------------------------------- */

// A line of text. `size` scales the UI font. Outside a window it gets a drop shadow, so it reads over any scene.
// zh: 一行文字。`大小` 是界面字号的倍数。不在窗口里时带阴影，画在什么背景上都看得清。
@(lua=text, table=UI, lua_zh="文字")
ui_lua_text :: proc(text: string, color: vec4 = {1, 1, 1, 1}, size: f32 = 1) {
    if !ui_lua_ready() do return
    t := fmt.ctprint(text)
    im.PushFontFloat(nil, ui_font_size() * size)
    defer im.PopFont()
    if lua_ui.windows == 0 {
        p := im.GetCursorScreenPos() + 2 * app.display_scale
        im.DrawList_AddTextImFontPtr(im.GetWindowDrawList(), im.GetFont(), im.GetFontSize(), p, im.ColorConvertFloat4ToU32({0, 0, 0, 0.75 * color.a}), t)
    }
    im.PushStyleColorImVec4(.Text, color)
    im.TextUnformatted(t)
    im.PopStyleColor()
}

// A bar filled to `fraction` (0 to 1): health, a timer. `w`, `h` are fractions of the view; 0 is the default, a
// quarter of the view wide and one line high. For a label, put a UI.text beside it with UI.same_line.
// zh: 填到 `比例`（0 到 1）的进度条：血量、计时。`宽`、`高` 按视口宽高的比例算；0 是默认，视口宽度的四分之一、一行高。
//     要标签就用 界面.同一行 在旁边放一个 界面.文字。
@(lua=progress_bar, table=UI, lua_zh="进度条")
ui_lua_progress_bar :: proc(fraction: f32, w: f32 = 0, h: f32 = 0) {
    if !ui_lua_ready() do return
    view := lua_ui.hi - lua_ui.lo
    size := im.Vec2{(w > 0 ? w : 0.25) * view.x, h * view.y}
    im.ProgressBar(fraction, size, "")
}

/* --------------------------------- Windows -------------------------------- */

// Opens a window: a panel the following widgets go in, until UI.end_window. Its point (x, y) sits at the same
// fractions of the view (0.5, 0.5 centres it; 1, 1 puts it in the bottom-right corner). `w`, `h` are fractions of the
// view; 0 fits the contents. `title` is its heading ("" for none) and tells two windows apart.
// zh: 打开一个窗口：后面的控件都放进这个面板，直到 界面.窗口结束。窗口上比例为 (x, y) 的点放在视口里同样比例的位置
//     （0.5, 0.5 居中；1, 1 放在右下角）。`宽`、`高` 按视口宽高的比例算；0 是按内容自动大小。`标题` 是它的标题（"" 表示没有），
//     也用来区分两个窗口。
@(lua=begin_window, table=UI, lua_zh="窗口开始")
ui_lua_begin_window :: proc(title: string, x: f32, y: f32, w: f32 = 0, h: f32 = 0) {
    if !ui_lua_ready() do return
    view := lua_ui.hi - lua_ui.lo
    flags: im.ChildFlags = {.Borders}
    if w <= 0 do flags += {.AutoResizeX}
    if h <= 0 do flags += {.AutoResizeY}
    im.SetCursorScreenPos(lua_ui.lo)   // EndChild lays the window out as an item at the cursor: keep that inside the view
    im.SetNextWindowPos(ui_lua_point(x, y), {}, {x, y})
    im.PushStyleColorImVec4(.ChildBg, im.GetStyleColorVec4(.WindowBg)^)
    im.PushStyleVarImVec2(.WindowPadding, {10 * app.display_scale, 8 * app.display_scale})
    im.BeginChild(fmt.ctprintf("%s##lua_window", title), {w * view.x, h * view.y}, flags)
    im.PopStyleVar()
    im.PopStyleColor()
    lua_ui.windows += 1
    if title != "" do ui_heading(fmt.ctprint(title))
}

// Closes the window UI.begin_window opened.
// zh: 关闭 界面.窗口开始 打开的窗口。
@(lua=end_window, table=UI, lua_zh="窗口结束")
ui_lua_end_window :: proc() {
    if !ui_lua_ready() do return
    if lua_ui.windows == 0 { ui_lua_error("Lua: UI.end_window without a UI.begin_window"); return }
    ui_lua_window_close()
}

/* ---------------------------------- Input --------------------------------- */
// Widgets need the mouse: unlock it (Input.lock_mouse(false)) while a menu is up. `label` is shown and also tells
// widgets apart, so two with the same label in one window need a hidden suffix: "OK##2".

// A button; true on the frame it's clicked.
// zh: 一个按钮；被点击的那一帧返回真。
@(lua=button, table=UI, lua_zh="按钮")
ui_lua_button :: proc(label: string) -> bool {
    if !ui_lua_ready() do return false
    return im.Button(fmt.ctprint(label))
}

// A checkbox showing `value`; returns the value, flipped on the frame it's clicked. Store it back where it came from.
// zh: 显示 `值` 的勾选框；返回这个值，被点击的那一帧取反。把它存回原来的地方。
@(lua=checkbox, table=UI, lua_zh="勾选框")
ui_lua_checkbox :: proc(label: string, value: bool) -> bool {
    v := value
    if ui_lua_ready() do im.Checkbox(fmt.ctprint(label), &v)
    return v
}

// A slider showing `value` between `min_value` and `max_value`; returns the value, changed while it's dragged. Store
// it back where it came from.
// zh: 显示 `值` 的滑块，范围 `最小值` 到 `最大值`；返回这个值，拖动时会变。把它存回原来的地方。
@(lua=slider, table=UI, lua_zh="滑块")
ui_lua_slider :: proc(label: string, value: f32, min_value: f32, max_value: f32) -> f32 {
    v := value
    if ui_lua_ready() do im.SliderFloat(fmt.ctprint(label), &v, min_value, max_value, "%.2f")
    return v
}
