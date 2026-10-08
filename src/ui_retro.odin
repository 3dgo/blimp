package blimp

import "core:fmt"
import im "lib:odin-imgui"

// Retro Look window: a world's retro settings (World_Settings.retro), effect by effect: what its views in
// render mode .Retro show. Opened from the button beside the retro toggle in a viewport toolbar. Like World
// Settings it shows the world the view shows (during play the play copy, whose edits go with it at Stop),
// and edits are undoable the same way.
@(private="file")
retro_ui: Settings_Window

RETRO_WINDOW_SIZE :: [2]f32{400, 700}   // first-open size (× display scale)

ui_retro_toggle   :: proc(w: ^World) { settings_window_toggle(&retro_ui, w) }
ui_retro_open_for :: proc(w: ^World) -> bool { return settings_window_open_for(&retro_ui, w) }
ui_retro_retarget :: proc(from, to: ^World) { settings_window_retarget(&retro_ui, from, to) }
ui_retro_forget   :: proc(w: ^World) { settings_window_forget(&retro_ui, w) }

ui_draw_retro :: proc() {
    w := retro_ui.world
    if w == nil do return
    open := true
    s := app.display_scale
    im.SetNextWindowSize({RETRO_WINDOW_SIZE.x * s, RETRO_WINDOW_SIZE.y * s}, .FirstUseEver)
    defer if !open do retro_ui.world = nil
    defer im.End()
    if !im.Begin(fmt.ctprintf("%s — %s###retro", tr(.Win_Retro), w.title), &open) do return
    ui_world_unsaved_note(w)

    before := w.settings
    ui_retro_settings(&w.settings.retro)
    settings_window_track_edit(&retro_ui, before)
}

// The PS1 group with its switch; under it each effect's switch, and under that its amounts, disabled while
// the effect or the group is off.
@(private="file")
ui_retro_settings :: proc(r: ^Retro_Settings) {
    labels := [?]Loc_ID{.Retro_On, .Retro_Low_Res, .Retro_Lines, .Retro_Vertex_Snap, .Retro_Snap, .Retro_Affine,
        .Retro_Warp, .Retro_Point_Sampling, .Retro_Quantize, .Retro_Color_Bits, .Retro_Dither}
    o := DEFAULT_PARAM_UI_OPTIONS
    o.label_w = ui_label_column(labels[:]) + im.GetStyle().IndentSpacing   // amounts are indented under their effect

    p := &r.ps1
    im.SeparatorText(tr(.Retro_PS1))
    im.PushID("ps1")   // both groups have an "On"
    ui_param_bool(string(tr(.Retro_On)), &p.on, o)
    im.BeginDisabled(!p.on)
    retro_effect(.Retro_Low_Res, &p.low_res, o)
    ui_param_label(string(tr(.Retro_Lines)), o)
    im.SliderInt("##lines", &p.lines, 120, 480, "%d", {.ClampOnInput})
    im.SetItemTooltip("%s", tr(.Retro_Lines_Tip))
    retro_effect_end()
    retro_effect(.Retro_Vertex_Snap, &p.vertex_snap, o)
    retro_slider(.Retro_Snap, &p.snap, 0.5, 4, o)
    retro_effect_end()
    retro_effect(.Retro_Affine, &p.affine, o)
    retro_slider(.Retro_Warp, &p.warp, 0, 1, o)
    retro_effect_end()
    ui_param_bool(string(tr(.Retro_Point_Sampling)), &p.point_sampling, o)
    retro_effect(.Retro_Quantize, &p.quantize, o)
    ui_param_label(string(tr(.Retro_Color_Bits)), o)
    im.SliderInt("##color_bits", &p.color_bits, RETRO_COLOR_BITS_MIN, 8, "%d", {.ClampOnInput})
    retro_slider(.Retro_Dither, &p.dither, 0, 1, o)
    retro_effect_end()
    im.EndDisabled()
    im.PopID()

    im.Separator()
    if im.Button(tr(.Btn_Retro_Defaults)) do r^ = RETRO_SETTINGS_DEFAULT
    im.TextDisabled("%s", tr(.Retro_Clean_Note))
}

// An effect's switch, then its amounts indented under it and disabled while it's off; close with
// retro_effect_end.
@(private="file")
retro_effect :: proc(label: Loc_ID, on: ^bool, o: Param_UI_Options) {
    ui_param_bool(string(tr(label)), on, o)
    im.Indent()
    im.BeginDisabled(!on^)
}

@(private="file")
retro_effect_end :: proc() {
    im.EndDisabled()
    im.Unindent()
}

// One amount, a slider over [lo, hi] (Ctrl+click to type a value, clamped to the range).
@(private="file")
retro_slider :: proc(label: Loc_ID, value: ^f32, lo, hi: f32, o: Param_UI_Options) {
    ui_param_label(string(tr(label)), o)
    im.SliderFloat(fmt.ctprintf("##%v", value), value, lo, hi, "%.2f", {.ClampOnInput})
}
