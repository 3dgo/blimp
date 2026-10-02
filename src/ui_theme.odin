package blimp

import im "lib:odin-imgui"

// The editor's ImGui look: VS Code's "Dark Modern" palette (neutral greys, #0078D4 blue accent,
// muted-blue selection) with Unity-like gentle rounding and flat, borderless frames. Replaces
// StyleColorsDark; sizes are authored at 1x and scaled by the display scale.
ui_apply_theme :: proc(scale: f32) {
    style := im.GetStyle()

    style.WindowPadding     = {8, 8}
    style.FramePadding      = {6, 3}
    style.ItemSpacing       = {8, 5}
    style.ItemInnerSpacing  = {6, 4}
    style.IndentSpacing     = 16
    style.ScrollbarSize     = 12
    style.GrabMinSize       = 10

    style.WindowRounding    = 4
    style.ChildRounding     = 4
    style.FrameRounding     = 3
    style.PopupRounding     = 4
    style.ScrollbarRounding = 6
    style.GrabRounding      = 3
    style.TabRounding       = 3

    style.WindowBorderSize  = 1
    style.ChildBorderSize   = 1
    style.PopupBorderSize   = 1
    style.FrameBorderSize   = 0
    style.TabBorderSize     = 0
    style.SeparatorTextBorderSize = 1
    style.DockingSeparatorSize    = 2

    im.Style_ScaleAllSizes(style, scale)

    hex :: proc(rgb: u32, a: f32 = 1) -> im.Vec4 {
        return {f32((rgb >> 16) & 0xFF) / 255, f32((rgb >> 8) & 0xFF) / 255, f32(rgb & 0xFF) / 255, a}
    }
    ACCENT       :: 0x0078D4   // VS Code focus / button blue
    ACCENT_LIGHT :: 0x4DAAFC
    SELECTION    :: 0x264F78   // VS Code selection blue (list selections, tree nodes)

    c := &style.Colors
    c[im.Col.Text]                  = hex(0xCCCCCC)
    c[im.Col.TextDisabled]          = hex(0x808080)
    c[im.Col.WindowBg]              = hex(0x1F1F1F)
    c[im.Col.ChildBg]               = hex(0x1F1F1F, 0)
    c[im.Col.PopupBg]               = hex(0x252526)
    c[im.Col.Border]                = hex(0x2B2B2B)
    c[im.Col.BorderShadow]          = hex(0x000000, 0)

    c[im.Col.FrameBg]               = hex(0x313131)
    c[im.Col.FrameBgHovered]        = hex(0x3C3C3C)
    c[im.Col.FrameBgActive]         = hex(0x45494E)

    c[im.Col.TitleBg]               = hex(0x181818)
    c[im.Col.TitleBgActive]         = hex(0x1F1F1F)
    c[im.Col.TitleBgCollapsed]      = hex(0x181818)
    c[im.Col.MenuBarBg]             = hex(0x181818)

    c[im.Col.ScrollbarBg]           = hex(0x181818, 0)
    c[im.Col.ScrollbarGrab]         = hex(0x424242)
    c[im.Col.ScrollbarGrabHovered]  = hex(0x4F4F4F)
    c[im.Col.ScrollbarGrabActive]   = hex(0x5A5A5A)

    c[im.Col.CheckMark]             = hex(0xFFFFFF)
    c[im.Col.CheckboxSelectedBg]    = hex(ACCENT)
    c[im.Col.SliderGrab]            = hex(ACCENT)
    c[im.Col.SliderGrabActive]      = hex(ACCENT_LIGHT)

    c[im.Col.Button]                = hex(0x313131)
    c[im.Col.ButtonHovered]         = hex(0x3C3C3C)
    c[im.Col.ButtonActive]          = hex(ACCENT)   // also marks the active toolbar tool

    // Header* = Selectable / TreeNode / CollapsingHeader / MenuItem. One colour has to serve both
    // "selected" and "hovered", so hover is a dim blue-grey that reads on either.
    c[im.Col.Header]                = hex(SELECTION)
    c[im.Col.HeaderHovered]         = hex(0x2A3F55)
    c[im.Col.HeaderActive]          = hex(0x094771)

    c[im.Col.Separator]             = hex(0x2B2B2B)
    c[im.Col.SeparatorHovered]      = hex(ACCENT)
    c[im.Col.SeparatorActive]       = hex(ACCENT_LIGHT)
    c[im.Col.ResizeGrip]            = hex(0x000000, 0)
    c[im.Col.ResizeGripHovered]     = hex(ACCENT, 0.6)
    c[im.Col.ResizeGripActive]      = hex(ACCENT)
    c[im.Col.InputTextCursor]       = hex(0xAEAFAD)

    // Tabs like VS Code's: the selected tab matches its panel and carries a thin accent line on top.
    c[im.Col.Tab]                   = hex(0x181818)
    c[im.Col.TabHovered]            = hex(0x2A2D2E)
    c[im.Col.TabSelected]           = hex(0x1F1F1F)
    c[im.Col.TabSelectedOverline]   = hex(ACCENT)
    c[im.Col.TabDimmed]             = hex(0x181818)
    c[im.Col.TabDimmedSelected]     = hex(0x1F1F1F)
    c[im.Col.TabDimmedSelectedOverline] = hex(0x4D4D4D)

    c[im.Col.DockingPreview]        = hex(ACCENT, 0.5)
    c[im.Col.DockingEmptyBg]        = hex(0x181818)

    c[im.Col.PlotLines]             = hex(0x9C9C9C)
    c[im.Col.PlotLinesHovered]      = hex(ACCENT_LIGHT)
    c[im.Col.PlotHistogram]         = hex(ACCENT)
    c[im.Col.PlotHistogramHovered]  = hex(ACCENT_LIGHT)

    c[im.Col.TableHeaderBg]         = hex(0x252526)
    c[im.Col.TableBorderStrong]     = hex(0x2B2B2B)
    c[im.Col.TableBorderLight]      = hex(0x262626)
    c[im.Col.TableRowBg]            = hex(0x000000, 0)
    c[im.Col.TableRowBgAlt]         = hex(0xFFFFFF, 0.03)

    c[im.Col.TextLink]              = hex(ACCENT_LIGHT)
    c[im.Col.TextSelectedBg]        = hex(SELECTION)
    c[im.Col.TreeLines]             = hex(0x585858)
    c[im.Col.DragDropTarget]        = hex(ACCENT)
    c[im.Col.DragDropTargetBg]      = hex(ACCENT, 0.15)
    c[im.Col.UnsavedMarker]         = hex(0xCCCCCC)
    c[im.Col.NavCursor]             = hex(ACCENT)
    c[im.Col.NavWindowingHighlight] = hex(0xFFFFFF, 0.7)
    c[im.Col.NavWindowingDimBg]     = hex(0x000000, 0.4)
    c[im.Col.ModalWindowDimBg]      = hex(0x000000, 0.5)
}
