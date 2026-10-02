package blimp

import "core:fmt"
import "core:mem"
import im "lib:odin-imgui"
import "dx"

// Probe Bake window: a level's bake settings (World_Settings.bake), the Bake button, what the last bake
// did, and the probe atlas (probe_grid_atlas). Opened from the bake button in a viewport toolbar. Always
// the level, never a play world, so it can be rebaked while playing. Settings edits are undoable like
// World Settings; the bake itself isn't an edit (editor_bake.odin).
@(private="file")
bake_ui: struct {
    world:      ^World,       // whose bake is shown; nil = window closed
    editing:    bool,         // a settings edit's undo step is open
    last:       Bake_Stats,   // the last bake this session, of last_world
    last_world: ^World,
}

BAKE_WINDOW_SIZE :: [2]f32{420, 520}   // first-open size (× display scale)
BAKE_ATLAS_MAX_SCALE :: 4              // the atlas fills the window's width, up to this many screen pixels per atlas pixel
PROBE_HIGHLIGHT_COLOR :: [4]f32{1, 0.85, 0.1, 1}   // the atlas probe under the mouse: its tile, and a square on it in the views

// The atlas probe under the mouse, shown in its world's views (editor_draw_probe_highlight) while it's fresh:
// set this UI frame or the last, since the views can draw before the atlas does.
@(private="file")
probe_highlight: struct {
    world: ^World,   // the level; nil = none
    probe: [3]i32,
    frame: i32,      // im.GetFrameCount() when set
}

ui_bake_toggle :: proc(level: ^World) {
    bake_ui.world = bake_ui.world == level ? nil : level
}

ui_bake_open_for :: proc(level: ^World) -> bool { return bake_ui.world == level }

// The world is closing.
ui_bake_forget :: proc(w: ^World) {
    if bake_ui.world == w do bake_ui.world = nil
    if bake_ui.last_world == w do bake_ui.last_world = nil
    if probe_highlight.world == w do probe_highlight = {}
}

ui_draw_bake :: proc() {
    w := bake_ui.world
    if w == nil do return
    open := true
    s := app.dispaly_scale
    im.SetNextWindowSize({BAKE_WINDOW_SIZE.x * s, BAKE_WINDOW_SIZE.y * s}, .FirstUseEver)
    defer if !open do bake_ui.world = nil
    defer im.End()
    if !im.Begin(fmt.ctprintf("%s — %s###bake", tr(.Win_Bake), w.title), &open) do return

    // Settings: undo detected after the fact, as in the World Settings window.
    before := w.settings
    opts := DEFAULT_PARAM_UI_OPTIONS
    opts.headerless = true
    ui_param_struct("bake", Bake_Settings, w.settings.bake, opts)
    if mem.compare_ptrs(&before, &w.settings, size_of(World_Settings)) != 0 && !bake_ui.editing {
        undo_push_settings_edited(w, before)
        bake_ui.editing = true
    }
    if !im.IsAnyItemActive() do bake_ui.editing = false

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
    up := probe_eval(g, probe_index(g, x, y, z), {0, 1, 0}, probe_layer_scales(g, light_group_scales(w, timer_sec_since_start())))

    tile := origin + scale * [2]f32{f32(col * (bw + PROBE_ATLAS_GAP) + int(x) * PROBE_ATLAS_TILE), f32(row * (bh + PROBE_ATLAS_GAP) + int(g.dims.z - 1 - z) * PROBE_ATLAS_TILE)}
    im.DrawList_AddRect(im.GetWindowDrawList(), tile, tile + scale * PROBE_ATLAS_TILE, im.GetColorU32ImVec4(PROBE_HIGHLIGHT_COLOR), 0, 2 * app.dispaly_scale)
    probe_highlight = {world_level(w), {x, y, z}, im.GetFrameCount()}
    if im.IsMouseDoubleClicked(.Left) {
        if ev := editor_view_for_world(w); ev != nil do camera_fit_bounds(&ev.view.camera, p - g.spacing * 0.5, p + g.spacing * 0.5)
    }
    im.SetTooltip("%s", fmt.ctprintf("[%d, %d, %d]  (%.2f, %.2f, %.2f)\n+Y  %.4f %.4f %.4f", x, y, z, p.x, p.y, p.z, up.x, up.y, up.z))
}

// The highlighted atlas probe as a yellow square on top of `ev`'s view (ui_overlay), sized to a fraction of
// the probe spacing on screen. Nothing unless the atlas is hovered and the view shows that level.
editor_draw_probe_highlight :: proc(ev: ^Editor_View) {
    hl := &probe_highlight
    if hl.world == nil || im.GetFrameCount() - hl.frame > 1 || world_level(ev.view.world) != hl.world do return
    g := &hl.world.probes
    if len(g.probes) == 0 do return
    p := probe_position(g, hl.probe.x, hl.probe.y, hl.probe.z)
    s, ok := ui_world_to_screen(ev, p)
    if !ok do return
    scale := app.dispaly_scale
    half := clamp(ui_overlay_pixels_per_unit(ev, p) * g.spacing * 0.15, 6 * scale, 40 * scale)
    o := ui_overlay_begin(ev)
    defer ui_overlay_end(o)
    col := im.GetColorU32ImVec4(PROBE_HIGHLIGHT_COLOR)
    im.DrawList_AddRect(o.dl, s - half, s + half, col, 0, 2 * scale)
    im.DrawList_AddCircleFilled(o.dl, s, 2 * scale, col)
}
