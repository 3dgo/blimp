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
    s := app.dispaly_scale
    im.SetNextWindowSize({RETRO_WINDOW_SIZE.x * s, RETRO_WINDOW_SIZE.y * s}, .FirstUseEver)
    defer if !open do retro_ui.world = nil
    defer im.End()
    if !im.Begin(fmt.ctprintf("%s — %s###retro", tr(.Win_Retro), w.title), &open) do return
    ui_world_unsaved_note(w)

    before := w.settings
    ui_retro_settings(&w.settings.retro)
    settings_window_track_edit(&retro_ui, before)
}

// Two groups, PS1 and CRT, each with its switch; under it each effect's switch, and under that its amounts,
// disabled while the effect or its group is off.
@(private="file")
ui_retro_settings :: proc(r: ^Retro_Settings) {
    labels := [?]Loc_ID{.Retro_On, .Retro_Low_Res, .Retro_Lines, .Retro_Vertex_Snap, .Retro_Snap, .Retro_Affine,
        .Retro_Warp, .Retro_Point_Sampling, .Retro_Quantize, .Retro_Color_Bits, .Retro_Dither, .Retro_Composite,
        .Retro_Luma_Blur, .Retro_Chroma_Blur, .Retro_Scanlines, .Retro_Strength, .Retro_Beam_Dark,
        .Retro_Beam_Bright, .Retro_Mask, .Retro_Bloom, .Retro_Radius, .Retro_Gamma, .Retro_Brightness}
    o := DEFAULT_PARAM_UI_OPTIONS
    for id in labels do o.label_w = max(o.label_w, im.CalcTextSize(tr(id)).x)
    o.label_w += im.GetStyle().IndentSpacing + 16 * app.dispaly_scale   // amounts are indented under their effect

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

    c := &r.crt
    im.SeparatorText(tr(.Retro_CRT))
    im.PushID("crt")
    ui_param_bool(string(tr(.Retro_On)), &c.on, o)
    im.BeginDisabled(!c.on)
    retro_effect(.Retro_Composite, &c.composite, o)
    retro_slider(.Retro_Luma_Blur, &c.luma_blur, 0, 3, o)
    retro_slider(.Retro_Chroma_Blur, &c.chroma_blur, 0, 5, o)
    retro_effect_end()
    retro_effect(.Retro_Scanlines, &c.scanlines, o)
    retro_slider(.Retro_Strength, &c.scanline_strength, 0, 1, o)
    retro_slider(.Retro_Beam_Dark, &c.beam_dark, 0.1, 1, o)
    retro_slider(.Retro_Beam_Bright, &c.beam_bright, 0.1, 1, o)
    retro_effect_end()
    retro_effect(.Retro_Mask, &c.mask, o)
    retro_slider(.Retro_Strength, &c.mask_strength, 0, 1, o)
    retro_effect_end()
    retro_effect(.Retro_Bloom, &c.bloom, o)
    retro_slider(.Retro_Strength, &c.bloom_strength, 0, 1, o)
    retro_slider(.Retro_Radius, &c.bloom_radius, 0.5, 16, o)
    retro_effect_end()
    im.SeparatorText(tr(.Retro_Tube))
    retro_slider(.Retro_Gamma, &c.gamma, 1.8, 3, o)
    im.SetItemTooltip("%s", tr(.Retro_Gamma_Tip))
    retro_slider(.Retro_Brightness, &c.brightness, 0.5, 2, o)
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
