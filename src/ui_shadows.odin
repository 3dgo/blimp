package blimp

import "core:fmt"
import im "lib:odin-imgui"
import "dx"

// Shadow Maps window (Show menu): the active world's shadow slices, how many of MAX_SHADOW_SLICES are in
// use and each one as grey depth labelled with its light. While it's open the renderer draws the slices
// into an atlas (render_shadows_debug_draw); hover a tile for it bigger.

SHADOW_WINDOW_SIZE :: [2]f32{720, 520}   // first-open size (× display scale)
SHADOW_TILE_SIZE   :: 128   // a slice in the grid, points (× display scale)
SHADOW_ZOOM_SIZE   :: 384   // the hovered slice in its tooltip

@(private="file")
SHADOW_FACES := [6]string{"+X", "-X", "+Y", "-Y", "+Z", "-Z"}

ui_draw_shadow_maps :: proc() {
    s := app.display_scale
    im.SetNextWindowSize({SHADOW_WINDOW_SIZE.x * s, SHADOW_WINDOW_SIZE.y * s}, .FirstUseEver)
    w := active_world()
    title := w != nil ? fmt.ctprintf("%s — %s###shadow_maps", tr(.Menu_Shadow_Maps), w.title) : fmt.ctprintf("%s###shadow_maps", tr(.Menu_Shadow_Maps))
    defer im.End()
    if !im.Begin(title, &ui.show_shadow_maps) do return
    if w == nil {
        im.TextDisabled("%s", tr(.Panel_No_World))
        return
    }
    render_shadows.debug_world = w   // drawn into the atlas this frame

    r := &w.render
    im.Text("%s", fmt.ctprintf(trs(.Shadow_Slices_Used), len(r.shadow_slices), MAX_SHADOW_SLICES))
    if r.shadow_missed > 0 {
        im.SameLine()
        im.TextColored({1, 0.35, 0.3, 1}, "%s", fmt.ctprintf(trs(.Shadow_Missed), r.shadow_missed))
    }
    if len(r.shadow_slices) == 0 {
        im.TextDisabled("%s", tr(.Shadow_None))
        return
    }
    im.TextDisabled("%s", tr(.Shadow_Legend))
    if render_shadows.debug_atlas.handle == nil do return   // the renderer makes it after this window's first frame
    gpu := dx.descriptor_heap_gpu_handle_at(renderer_dx.ui_heap, render_shadows.debug_atlas_ui.heap_slot)
    tex := im.TextureRef{_TexID = im.TextureID(gpu.ptr)}

    // Fixed-width columns, as many as fit: a long light name is clipped to its tile.
    tile := SHADOW_TILE_SIZE * s
    cols := max(1, int(im.GetContentRegionAvail().x / (tile + im.GetStyle().CellPadding.x * 2)))
    if !im.BeginTable("##slices", i32(cols)) do return
    defer im.EndTable()
    for _ in 0..<cols do im.TableSetupColumn("", {.WidthFixed}, tile)
    for &slice, i in r.shadow_slices {
        im.TableNextColumn()
        uv0, uv1 := shadow_tile_uv(i)
        im.Image(tex, {tile, tile}, uv0, uv1)
        hovered := im.IsItemHovered()
        name := sbuf_str(&slice.light)
        kind, _ := entity_flag_item_label("EntityLightType", fmt.tprint(slice.light_type))
        if name == "" do name = kind
        face := slice.light_type == .Point ? SHADOW_FACES[slice.face] : ""
        im.Text("%s", fmt.ctprintf("%d %s", i, face))
        im.TextDisabled("%s", fmt.ctprintf("%s", name))
        if !hovered do continue

        im.BeginTooltip()
        im.Text("%s", fmt.ctprintf("%s", name))
        im.TextDisabled("%s", fmt.ctprintf("%s %s · %d", kind, face, i))
        texel := slice.far > 0 ? fmt.ctprintf(trs(.Shadow_Texel_At_1m), slice.texel) : fmt.ctprintf(trs(.Shadow_Texel), slice.texel)
        im.TextDisabled("%s", texel)
        im.Image(tex, {SHADOW_ZOOM_SIZE * s, SHADOW_ZOOM_SIZE * s}, uv0, uv1)
        im.EndTooltip()
    }
}

// Slice `i`'s tile in the atlas (SHADOW_DEBUG_COLS across), as UVs.
@(private="file")
shadow_tile_uv :: proc(i: int) -> (uv0, uv1: im.Vec2) {
    size := im.Vec2{1.0 / SHADOW_DEBUG_COLS, 1.0 / SHADOW_DEBUG_ROWS}
    uv0 = {f32(i % SHADOW_DEBUG_COLS), f32(i / SHADOW_DEBUG_COLS)} * size
    return uv0, uv0 + size
}
