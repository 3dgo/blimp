package blimp

import "core:fmt"
import im "lib:odin-imgui"

// A row of view actions above the image. The window has zero padding (the image runs edge to edge),
// so the row indents itself. Save, play controls, then world settings and the view toggles. The
// transform tools are a column down the left instead (ui_view_tools), so this row stays short.
ui_view_toolbar :: proc(view: ^Render_View) {
    style := im.GetStyle()
    im.SetCursorPos(im.GetCursorPos() + style.FramePadding)

    // Save first, set apart from the rest. Saves the level; disabled while playing, so nothing is ever
    // saved from play (Stop first).
    w := view.world
    level := world_level(w)
    playing := world_playing(w)
    im.BeginDisabled(!world_dirty(level) || playing)   // nothing to save: a kit, or no changes since the last save
    if im.Button(fmt.ctprintf("%s##save", ICON_SAVE)) do world_save(level)
    im.EndDisabled()
    if im.IsItemHovered(im.HoveredFlags_AllowWhenDisabled) {
        switch {
        case playing:               im.SetTooltip("%s", tr(.Play_No_Save))
        case level.save_path == "": im.SetTooltip("%s", tr(.Inspector_Kit_Warning))
        case !world_dirty(level):   im.SetTooltip("%s", tr(.Save_No_Changes))
        case:                       im.SetTooltip("%s  %s  (Ctrl+S)", tr(.Btn_Save_Level), fmt.ctprintf("%s", level.save_path))
        }
    }
    im.SameLine(0, style.ItemSpacing.x * 3)

    // Play / Pause / Step (world_play.odin). Play turns into Stop while playing; Stop is also the reset, since
    // the next Play starts from a fresh copy of the level.
    if toggle_button(fmt.ctprintf("%s##play", playing ? ICON_STOP : ICON_PLAY), playing) {
        if playing do world_stop(w)
        else       do ui_play(view)   // and shows it as the game (ui_game.odin)
    }
    im.SetItemTooltip("%s  (%s)", playing ? tr(.Play_Stop) : tr(.Play_Play), playing ? cstring("F7") : cstring("F5"))
    im.SameLine()
    im.BeginDisabled(!playing)
    if toggle_button(fmt.ctprintf("%s##pause", ICON_PAUSE), playing && w.paused) do world_pause_toggle(w)
    im.SetItemTooltip("%s  (F6)", tr(.Play_Pause))
    im.EndDisabled()
    im.SameLine()
    im.BeginDisabled(!playing || !w.paused)   // stepping only means something while paused
    if im.Button(fmt.ctprintf("%s##step", ICON_STEP)) do world_step(w)
    im.EndDisabled()
    im.SetItemTooltip("%s  (F10)", tr(.Play_Step))
    im.SameLine(0, style.ItemSpacing.x * 3)

    // World settings ([world] section): background, Lua script, …
    if toggle_button(fmt.ctprintf("%s##settings", ICON_SETTINGS), ui_world_settings_open_for(w)) do ui_world_settings_toggle(w)
    im.SetItemTooltip("%s", tr(.Win_World_Settings))
    im.SameLine()
    game_view := editor_view(view).game_view
    if toggle_button(fmt.ctprintf("%s##gameview", ICON_GAME_VIEW), game_view) do ui_game_view_toggle(view)
    im.SetItemTooltip("%s  (G)", tr(.Tool_Game_View))
    im.SameLine()
    maximized := ui.maximized == view
    if toggle_button(fmt.ctprintf("%s##maximize", maximized ? ICON_FULLSCREEN_EXIT : ICON_FULLSCREEN), maximized) do ui_maximize_toggle(view)
    im.SetItemTooltip("%s  (F11)", tr(.Tool_Maximize))
}

// The transform tools, a column down the left of the image: the four tools as icons, then what they
// act in (space, pivot) as the icon over the current mode's short name, then the snap toggle and step.
// Shared by every view. As wide as the longest mode name in either state, so toggling a mode never
// shifts the image beside it.
ui_view_tools :: proc() {
    style := im.GetStyle()
    labels := [?]cstring{tr(.Tool_Space_Global), tr(.Tool_Space_Local), tr(.Tool_Pivot_Center), tr(.Tool_Pivot_Individual)}
    width := im.CalcTextSize(ICON_MOVE).x   // icon glyphs share one advance
    im.PushFontFloat(nil, 16 * app.dispaly_scale * TOOL_LABEL_SCALE)
    for l in labels do width = max(width, im.CalcTextSize(l).x)
    im.PopFont()
    width += 2 * style.FramePadding.x * TOOL_PAD_SCALE
    im.SetCursorPosX(im.GetCursorPosX() + style.FramePadding.x)
    im.BeginGroup()

    tool_button :: proc(tool: Edit_Tool, icon: string, name: cstring, key: string, width: f32) {
        if toggle_button(fmt.ctprintf("%s##tool%v", icon, tool), ui.tool == tool, {width, 0}) do ui.tool = tool
        im.SetItemTooltip("%s  (%s)", name, fmt.ctprintf("%s", key))
    }
    tool_button(.Select, ICON_SELECT, tr(.Tool_Select), "Q", width)
    tool_button(.Move,   ICON_MOVE,   tr(.Tool_Move),   "W", width)
    tool_button(.Rotate, ICON_ROTATE, tr(.Tool_Rotate), "E", width)
    tool_button(.Scale,  ICON_SCALE,  tr(.Tool_Scale),  "R", width)
    im.Dummy({0, style.ItemSpacing.y})

    // Modes, each naming the current one under its icon. Reference space for move/rotate (scale is
    // always local), then what rotate/scale turn a multi-selection about.
    global := ui.space == .Global
    if stacked_button("##space", global ? ICON_GLOBAL : ICON_LOCAL, global ? tr(.Tool_Space_Global) : tr(.Tool_Space_Local), width) {
        ui.space = global ? .Local : .Global
    }
    im.SetItemTooltip("%s  (X)", tr(.Tool_Space_Tip))
    center := ui.pivot == .Selection_Center
    if stacked_button("##pivot", center ? ICON_PIVOT_CENTER : ICON_PIVOT_EACH, center ? tr(.Tool_Pivot_Center) : tr(.Tool_Pivot_Individual), width) {
        ui.pivot = center ? .Individual_Pivots : .Selection_Center
    }
    im.SetItemTooltip("%s  (Z)", tr(.Tool_Pivot_Tip))
    im.Dummy({0, style.ItemSpacing.y})

    // Snapping: the toggle, then the step right under it (Ctrl inverts the toggle mid-drag). Always
    // shown so it's findable: the active tool's step, the move step while selecting.
    if toggle_button(fmt.ctprintf("%s##snap", ICON_SNAP), ui.snap.enabled, {width, 0}) do ui.snap.enabled = !ui.snap.enabled
    im.SetItemTooltip("%s — %s", tr(.Tool_Snap), tr(.Tool_Snap_Tip))
    step, format, name := &ui.snap.move, cstring("%.2f"), tr(.Tool_Move)
    #partial switch ui.tool {
    case .Rotate: step, format, name = &ui.snap.angle, "%.0f°", tr(.Tool_Rotate)
    case .Scale:  step, format, name = &ui.snap.scale, "%.2f",  tr(.Tool_Scale)
    }
    im.SetNextItemWidth(width)
    im.DragFloat("##snap_step", step, 0.01 if ui.tool != .Rotate else 1, 0.01, 360, format)
    im.SetItemTooltip("%s: %s", tr(.Tool_Snap), name)
    im.EndGroup()
}

TOOL_LABEL_SCALE :: 0.9   // the mode names under their icons in the tool column, × the UI font size
TOOL_PAD_SCALE   :: 0.5   // padding around the tool column's content, × style.FramePadding

// A button `width` wide with `icon` centred above a short `text` in a slightly smaller font. ImGui
// left-aligns the lines of a multi-line label (and has one font size per label), so both are drawn
// over a blank button.
@(private="file")
stacked_button :: proc(id: cstring, icon: string, text: cstring, width: f32) -> (clicked: bool) {
    style := im.GetStyle()
    line := im.GetFontSize()
    small := 16 * app.dispaly_scale * TOOL_LABEL_SCALE
    pad := style.FramePadding.y * TOOL_PAD_SCALE
    clicked = im.Button(id, {width, line + small + 2 * pad})
    mn, mx := im.GetItemRectMin(), im.GetItemRectMax()
    dl := im.GetWindowDrawList()
    col := im.GetColorU32ImVec4(style.Colors[im.Col.Text])
    icon_c := fmt.ctprintf("%s", icon)
    cx := (mn.x + mx.x) * 0.5
    y := mn.y + pad
    im.DrawList_AddText(dl, {cx - im.CalcTextSize(icon_c).x * 0.5, y}, col, icon_c)
    im.PushFontFloat(nil, small)
    im.DrawList_AddText(dl, {cx - im.CalcTextSize(text).x * 0.5, y + line}, col, text)
    im.PopFont()
    return
}

// A toggle drawn as a button, lit with the accent colour while on. Hovering an on button lightens
// the accent instead of falling back to the grey hover colour, so it still reads as on.
@(private="file")
toggle_button :: proc(label: cstring, on: bool, size: [2]f32 = {}) -> (clicked: bool) {
    if on {
        accent := im.GetStyleColorVec4(.ButtonActive)^
        hover  := accent + ({1, 1, 1, 1} - accent) * 0.15
        hover.w = accent.w
        im.PushStyleColorImVec4(.Button, accent)
        im.PushStyleColorImVec4(.ButtonHovered, hover)
    }
    clicked = im.Button(label, size)
    if on do im.PopStyleColor(2)
    return
}
