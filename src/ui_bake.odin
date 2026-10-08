package blimp

import "core:fmt"
import "core:math"
import im "lib:odin-imgui"
import "dx"

// Probe Bake window: a level's bake settings (World_Settings.bake), the Bake button, what the last bake
// did, and the probe atlas (probe_grid_atlas). Opened from the bake button in a viewport toolbar. Always
// the level, never a play world, so it can be rebaked while playing. Settings edits are undoable like
// World Settings; the bake itself isn't an edit (editor_bake.odin).
@(private="file")
bake_ui: struct {
    using window: Settings_Window,   // always a level: probes are level data, so it doesn't follow Play
    last:       Bake_Stats,   // the last bake this session, of last_world
    last_world: ^World,
}

BAKE_WINDOW_SIZE :: [2]f32{420, 520}   // first-open size (× display scale)
BAKE_ATLAS_MAX_SCALE :: 4              // the atlas fills the window's width, up to this many screen pixels per atlas pixel
PROBE_HIGHLIGHT_COLOR :: [4]f32{1, 0.85, 0.1, 1}   // the atlas probe under the mouse: its tile, and a square on it in the views

// The atlas probe under the mouse, shown in its world's views (ui_bake_probe_highlight) while it's fresh:
// set this UI frame or the last, since the views can draw before the atlas does.
@(private="file")
probe_highlight: struct {
    world: ^World,   // the level; nil = none
    probe: [3]i32,
    frame: i32,      // im.GetFrameCount() when set
}

ui_bake_toggle   :: proc(level: ^World) { settings_window_toggle(&bake_ui.window, level) }
ui_bake_open_for :: proc(level: ^World) -> bool { return settings_window_open_for(&bake_ui.window, level) }

// The world is closing.
ui_bake_forget :: proc(w: ^World) {
    settings_window_forget(&bake_ui.window, w)
    if bake_ui.last_world == w do bake_ui.last_world = nil
    if probe_highlight.world == w do probe_highlight = {}
}

ui_draw_bake :: proc() {
    w := bake_ui.world
    if w == nil do return
    open := true
    s := app.display_scale
    im.SetNextWindowSize({BAKE_WINDOW_SIZE.x * s, BAKE_WINDOW_SIZE.y * s}, .FirstUseEver)
    defer if !open do bake_ui.world = nil
    defer im.End()
    if !im.Begin(fmt.ctprintf("%s — %s###bake", tr(.Win_Bake), w.title), &open) do return

    before := w.settings
    ui_bake_settings(w)
    settings_window_track_edit(&bake_ui.window, before)

    // Bake before drawing the atlas: a bake replaces the atlas texture, and this frame's draw list must
    // not hold the old one.
    im.Separator()
    if im.Button(tr(.Btn_Bake_Probes)) {
        if stats, ok := bake_probes(w); ok do bake_ui.last, bake_ui.last_world = stats, w
    }
    im.SameLine()
    g := &w.probes
    if len(g.probes) == 0 {
        im.TextDisabled("%s", tr(.Bake_None))
        return
    }
    im.TextUnformatted(fmt.ctprintf(string(tr(.Bake_Status)), g.dims.x, g.dims.y, g.dims.z, g.layers))
    if bake_ui.last_world == w {
        l := bake_ui.last
        im.TextDisabled("%s", fmt.ctprintf(string(tr(.Bake_Last)), l.seconds, l.threads, l.instances, l.lights, 100 * l.backface, l.buried))
    }

    im.Separator()
    im.TextUnformatted(tr(.Bake_Atlas))
    im.SameLine()
    im.TextDisabled("(?)")
    if im.BeginItemTooltip() {
        im.PushTextWrapPos(im.GetFontSize() * 30)
        im.TextUnformatted(tr(.Bake_Atlas_Tip))
        im.PopTextWrapPos()
        im.EndTooltip()
    }
    ui_probe_atlas_image(w, im.GetContentRegionAvail().x)
}

BAKE_QUALITY_LABELS := [Bake_Quality]Loc_ID{.Draft = .Bake_Quality_Draft, .Medium = .Bake_Quality_Medium, .High = .Bake_Quality_High, .Custom = .Bake_Quality_Custom}
BAKE_BOUNDS_LABELS  := [Bake_Bounds]Loc_ID{.Auto = .Bake_Bounds_Auto, .Manual = .Bake_Bounds_Manual}
BAKE_BOUNDS_COLOR   :: vec4{1, 0.85, 0.1, 1}   // the manual grid box in the level's views while this window is open

// Bake_Settings as a form, drawn by hand: a quality preset fills rays and bounces (editing either makes it
// Custom), rows that do nothing in the current mode are disabled or hidden.
@(private="file")
ui_bake_settings :: proc(w: ^World) {
    b := &w.settings.bake
    labels := [?]Loc_ID{.Bake_Quality, .Bake_Rays, .Bake_Bounces, .Bake_Sky, .World_Sky_Intensity,
        .World_Probe_Spacing, .Bake_Bounds, .Bake_Bounds_Min, .Bake_Bounds_Max}
    o := DEFAULT_PARAM_UI_OPTIONS
    o.label_w = ui_label_column(labels[:])

    im.SeparatorText(tr(.Bake_Section_Quality))
    ui_param_label(string(tr(.Bake_Quality)), o)
    if im.BeginCombo("##quality", tr(BAKE_QUALITY_LABELS[b.quality])) {
        for q in Bake_Quality {
            if !im.Selectable(tr(BAKE_QUALITY_LABELS[q]), q == b.quality) do continue
            b.quality = q
            if q != .Custom do b.rays, b.bounces = BAKE_QUALITY_PRESETS[q][0], BAKE_QUALITY_PRESETS[q][1]
        }
        im.EndCombo()
    }
    ui_param_label(string(tr(.Bake_Rays)), o)
    if im.SliderInt("##rays", &b.rays, BAKE_RAYS_MIN, BAKE_RAYS_MAX, "%d", {.Logarithmic, .ClampOnInput}) do b.quality = .Custom
    ui_param_label(string(tr(.Bake_Bounces)), o)
    if im.SliderInt("##bounces", &b.bounces, 1, BAKE_BOUNCES_MAX, "%d", {.ClampOnInput}) do b.quality = .Custom

    im.SeparatorText(tr(.Bake_Section_Sky))
    ui_param_bool(string(tr(.Bake_Sky)), &b.sky, o)
    im.BeginDisabled(!b.sky)
    oi := o
    oi.max = 1000
    ui_param_f32(string(tr(.World_Sky_Intensity)), &b.sky_intensity, oi)
    im.EndDisabled()

    im.SeparatorText(tr(.Bake_Section_Grid))
    os := o
    os.min, os.max, os.format = 0.05, 100, "%.2f"
    ui_param_f32(string(tr(.World_Probe_Spacing)), &b.probe_spacing, os)
    ui_param_label(string(tr(.Bake_Bounds)), o)
    if im.BeginCombo("##bounds", tr(BAKE_BOUNDS_LABELS[b.bounds])) {
        for m in Bake_Bounds {
            if !im.Selectable(tr(BAKE_BOUNDS_LABELS[m]), m == b.bounds) do continue
            b.bounds = m
            // A box that was never set starts as the one Auto would fill.
            if m == .Manual && b.bounds_min == b.bounds_max {
                if lo, hi, ok := bake_auto_bounds(w); ok do b.bounds_min, b.bounds_max = lo, hi
            }
        }
        im.EndCombo()
    }
    if b.bounds != .Manual do return
    ob := o
    ob.speed, ob.format = 0.1, "%.2f"
    ui_param_vec3(string(tr(.Bake_Bounds_Min)), &b.bounds_min, ob)
    ui_param_vec3(string(tr(.Bake_Bounds_Max)), &b.bounds_max, ob)
    if im.Button(tr(.Btn_Bake_Fit)) {
        if lo, hi, ok := bake_auto_bounds(w); ok do b.bounds_min, b.bounds_max = lo, hi
    }
    // The probe count this box gives, as bake_probes sizes the grid; red over MAX_PROBES.
    im.SameLine()
    spacing := max(b.probe_spacing, 0.05)
    count := 1
    for a in 0..<3 do count *= int(math.ceil(max(b.bounds_max[a] - b.bounds_min[a], 0) / spacing)) + 1
    text := fmt.ctprintf(string(tr(.Bake_Estimate)), count, MAX_PROBES)
    if count > MAX_PROBES do im.TextColored({1, 0.35, 0.3, 1}, "%s", text)
    else do im.TextDisabled("%s", text)
}

// The manual grid box as scene lines in the level's views (ui_view_debug_lines), while the Bake window
// shows that level.
ui_bake_bounds_lines :: proc(level: ^World) {
    if bake_ui.world != level || level.settings.bake.bounds != .Manual do return
    lo, hi := level.settings.bake.bounds_min, level.settings.bake.bounds_max
    debug_box((lo + hi) * 0.5, (hi - lo) * 0.5, BAKE_BOUNDS_COLOR)
}

// The probe atlas at `width` (at most BAKE_ATLAS_MAX_SCALE× its pixels). The probe under the mouse gets a
// yellow outline here and a yellow square in the world's views, a tooltip (grid index, position, irradiance
// facing up), and double-clicking it frames it in the world's view. Shared with the Resources window.
ui_probe_atlas_image :: proc(w: ^World, width: f32) {
    g := &w.probes
    a := g.atlas
    if w.render.probe_atlas.resource.handle == nil || a.width == 0 do return
    scale := min(width / f32(a.width), BAKE_ATLAS_MAX_SCALE)
    origin := im.GetCursorScreenPos()
    gpu := dx.descriptor_heap_gpu_handle_at(renderer_dx.ui_heap, w.render.probe_atlas_ui.heap_slot)
    im.Image(im.TextureRef{_TexID = im.TextureID(gpu.ptr)}, {f32(a.width) * scale, f32(a.height) * scale})
    if !im.IsItemHovered() do return

    // Atlas pixel → layer block → tile (probe_grid_atlas's layout).
    px := (im.GetMousePos() - origin) / scale
    bw, bh := int(g.dims.x) * PROBE_ATLAS_TILE, int(g.dims.z) * PROBE_ATLAS_TILE
    cols := (int(a.width) + PROBE_ATLAS_GAP) / (bw + PROBE_ATLAS_GAP)
    col, row := int(px.x) / (bw + PROBE_ATLAS_GAP), int(px.y) / (bh + PROBE_ATLAS_GAP)
    in_x, in_y := int(px.x) - col * (bw + PROBE_ATLAS_GAP), int(px.y) - row * (bh + PROBE_ATLAS_GAP)
    y := i32(row * cols + col)
    if in_x < 0 || in_x >= bw || in_y < 0 || in_y >= bh || y >= g.dims.y do return
    x := i32(in_x / PROBE_ATLAS_TILE)
    z := g.dims.z - 1 - i32(in_y / PROBE_ATLAS_TILE)
    p := probe_position(g, x, y, z)
    up := probe_eval(g, probe_index(g, x, y, z), {0, 1, 0}, probe_layer_scales(g, light_group_scales(w)))

    tile := origin + scale * [2]f32{f32(col * (bw + PROBE_ATLAS_GAP) + int(x) * PROBE_ATLAS_TILE), f32(row * (bh + PROBE_ATLAS_GAP) + int(g.dims.z - 1 - z) * PROBE_ATLAS_TILE)}
    im.DrawList_AddRect(im.GetWindowDrawList(), tile, tile + scale * PROBE_ATLAS_TILE, im.GetColorU32ImVec4(PROBE_HIGHLIGHT_COLOR), 0, 2 * app.display_scale)
    probe_highlight = {world_level(w), {x, y, z}, im.GetFrameCount()}
    if im.IsMouseDoubleClicked(.Left) {
        if ev := editor_view_for_world(w); ev != nil do camera_fit_bounds(&ev.view.camera, p - g.spacing * 0.5, p + g.spacing * 0.5)
    }
    im.SetTooltip("%s", fmt.ctprintf("[%d, %d, %d]  (%.2f, %.2f, %.2f)\n+Y  %.4f %.4f %.4f", x, y, z, p.x, p.y, p.z, up.x, up.y, up.z))
}

// The highlighted atlas probe as a yellow square on top of `ev`'s view (editor_overlay), sized to a fraction of
// the probe spacing on screen. Nothing unless the atlas is hovered and the view shows that level.
ui_bake_probe_highlight :: proc(ev: ^Editor_View) {
    hl := &probe_highlight
    if hl.world == nil || im.GetFrameCount() - hl.frame > 1 || world_level(ev.view.world) != hl.world do return
    g := &hl.world.probes
    if len(g.probes) == 0 do return
    p := probe_position(g, hl.probe.x, hl.probe.y, hl.probe.z)
    s, ok := world_to_screen(ev, p)
    if !ok do return
    scale := app.display_scale
    half := clamp(overlay_pixels_per_unit(ev, p) * g.spacing * 0.15, 6 * scale, 40 * scale)
    o := overlay_begin(ev)
    defer overlay_end(o)
    col := im.GetColorU32ImVec4(PROBE_HIGHLIGHT_COLOR)
    im.DrawList_AddRect(o.dl, s - half, s + half, col, 0, 2 * scale)
    im.DrawList_AddCircleFilled(o.dl, s, 2 * scale, col)
}
