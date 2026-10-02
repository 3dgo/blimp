package blimp

import "core:math"
import "core:math/linalg"
import hm "core:container/handle_map"

// What an entity is besides its model, made visible in the editor: a camera's frustum and a light's
// reach as scene lines (render_debug_draw.odin, drawn into each view's editor overlay by pick_view_debug_lines),
// and an icon at the entity on the view's overlay (ui_overlay.odin). Cameras and lights have no mesh, so
// without these they'd be invisible. Selected ones draw in the selection colours.

EDITOR_SHAPE_DEPTH       :: 5.0          // perspective frustums are drawn at most this deep, so a far plane of 1000 doesn't fill the view
EDITOR_SHAPE_ORTHO_DEPTH :: 200.0        // orthographic boxes: their real depth, within reason
EDITOR_SHAPE_ASPECT      :: 16.0 / 9.0   // a camera's real aspect comes from its target; the PS1 target is 16:9

EDITOR_SHAPE_CAMERA_COLOR :: vec4{0.8, 0.8, 0.85, 1}
EDITOR_SHAPE_LIGHT_COLOR  :: vec4{1, 0.8, 0.35, 1}

// `selected_color` is nil for an unselected entity, whose shape draws dimmed so a city's worth of reach
// spheres stays in the background; the selected ones stand out.
editor_entity_shapes :: proc(e: ^Entity, selected_color: Maybe(vec4)) {
    if .Enabled not_in e.basic_flags || .Hidden in e.basic_flags do return
    if e.camera_type == .None && e.light_type == .None do return
    right, up, forward := debug_axes_of(e.rotation)
    p := e.position

    cam_col := selected_color.? or_else editor_dim(EDITOR_SHAPE_CAMERA_COLOR)
    switch e.camera_type {
    case .None:
    case .Perspective:
        tan_half := math.tan(math.to_radians(e.fov) * 0.5)
        near, far := e.range.x, min(e.range.y, EDITOR_SHAPE_DEPTH)
        debug_frustum(p, e.rotation, near, far,
            {near * tan_half * EDITOR_SHAPE_ASPECT, near * tan_half}, {far * tan_half * EDITOR_SHAPE_ASPECT, far * tan_half}, cam_col)
    case .Orthographic:
        // A box doesn't widen with depth, so it's drawn at its real depth: it shows exactly what's seen.
        half := vec2{e.size.y * 0.5 * EDITOR_SHAPE_ASPECT, e.size.y * 0.5}
        debug_frustum(p, e.rotation, e.range.x, min(e.range.y, EDITOR_SHAPE_ORTHO_DEPTH), half, half, cam_col)
    }

    col := selected_color.? or_else editor_dim(editor_light_color(e))
    switch e.light_type {
    case .None:
    case .Directional:
        // The direction it shines, with a small ring around its tail.
        debug_arrow(p, p + forward * 1.5, col, 0.3)
        debug_circle(p, right, up, 0.25, col)
    case .Point:
        debug_sphere(p, e.range.y, col, e.rotation)   // its reach (falloff radius)
    case .Spot:
        half := math.to_radians(e.fov) * 0.5
        debug_cone(p, forward, e.range.y, half, col)   // out to its reach
    }
}

// A light's own colour, brightened so a dim one still reads (a black light falls back to amber).
@(private="file")
editor_light_color :: proc(e: ^Entity) -> vec4 {
    peak := max(e.color.r, e.color.g, e.color.b)
    if peak <= 0.001 do return EDITOR_SHAPE_LIGHT_COLOR
    return {e.color.r / peak, e.color.g / peak, e.color.b / peak, 1}
}


/* ---------------------------------- Icons ---------------------------------- */
// A camera or light also gets an icon at its position, like Unity's gizmo icons, drawn on the view's
// overlay (ui_overlay.odin). So that a city's hundreds of lights don't become a carpet of markers:
// - it has a size in the world, so it shrinks with distance (clamped between a few pixels and full size);
// - it fades out with distance and is gone past EDITOR_ICON_FADE_END;
// - it's hidden while geometry stands between it and the camera (a CPU ray against the picking BVH).
// Selected icons always stay faintly visible. What can be clicked or marquee'd is what's drawn.

EDITOR_ICON_WORLD_RADIUS       :: 0.5    // world units: an icon's size where it stands (full size within ~15 units)
EDITOR_ICON_MIN_PX             :: 6      // …never smaller on screen than this (× display scale), nor bigger than UI_OVERLAY_ICON_RADIUS
EDITOR_ICON_FADE_START         :: 40.0   // distance from the camera where icons start fading out
EDITOR_ICON_FADE_END           :: 80.0   // …and are gone
EDITOR_ICON_SELECTED_MIN_ALPHA :: 0.35   // a selected icon never fades or hides below this
EDITOR_ICON_RAYS_PER_FRAME     :: 48     // occlusion rays per view per frame; with more icons they take turns

// One icon as a view shows it this frame.
Editor_Icon :: struct {
    handle: Entity_Handle,
    icon:   string,
    center: vec2,   // screen
    radius: f32,    // pixels
    alpha:  f32,
}

// The icon `e` shows, if any: an enabled, unhidden camera or light. A light wins over a camera on the
// same entity (two roles are normally two entities).
editor_entity_icon :: proc(e: ^Entity) -> (icon: string, ok: bool) {
    if .Enabled not_in e.basic_flags || .Hidden in e.basic_flags do return
    switch e.light_type {
    case .None:
    case .Point:       return ICON_LIGHT_POINT, true
    case .Spot:        return ICON_LIGHT_SPOT, true
    case .Directional: return ICON_LIGHT_SUN, true
    }
    if e.camera_type != .None do return ICON_CAMERA, true
    return
}

// How `ev` shows `e`'s icon this frame; false when it shows none (no icon, off screen, faded out, or
// hidden behind geometry and not selected).
editor_icon_of :: proc(ev: ^Editor_View, e: ^Entity) -> (ic: Editor_Icon, ok: bool) {
    if ev.game_view do return   // G: no icons, so none to click either
    icon := editor_entity_icon(e) or_return
    center, front := ui_world_to_screen(ev, e.position)
    if !front do return
    full := UI_OVERLAY_ICON_RADIUS * app.dispaly_scale
    if !on_view(ev, center, full) do return

    dist := linalg.length(e.position - camera_eye(ev.view.camera))
    alpha := 1 - clamp((dist - EDITOR_ICON_FADE_START) / (EDITOR_ICON_FADE_END - EDITOR_ICON_FADE_START), 0, 1)
    if ev.icon_hidden[e.handle.idx] do alpha = 0
    if e.selected do alpha = max(alpha, EDITOR_ICON_SELECTED_MIN_ALPHA)
    if alpha <= 0.01 do return

    radius := clamp(EDITOR_ICON_WORLD_RADIUS * ui_overlay_pixels_per_unit(ev, e.position), EDITOR_ICON_MIN_PX * app.dispaly_scale, full)
    return {e.handle, icon, center, radius, alpha}, true
}

// Whether screen point `s` is on `ev`'s image, or within `margin` pixels of it.
@(private="file")
on_view :: proc(ev: ^Editor_View, s: vec2, margin: f32) -> bool {
    lo, hi := ev.screen_min - margin, ev.screen_min + ev.screen_size + margin
    return s.x >= lo.x && s.y >= lo.y && s.x <= hi.x && s.y <= hi.y
}

// Re-tests which icons geometry hides from `ev`'s camera: a ray from the eye to each icon against the
// scene (pick_entity, so hidden/disabled meshes don't block). Up to EDITOR_ICON_RAYS_PER_FRAME per frame,
// taking turns over the icons that could be seen (on screen, not faded out), so the cost stays flat
// however many lights there are; a hidden flag may lag the camera by a few frames. A light inside its own
// model (a lantern) isn't hidden by it.
editor_icons_update_occlusion :: proc(ev: ^Editor_View) {
    w := ev.view.world
    eye := camera_eye(ev.view.camera)
    candidates := make([dynamic]Entity_Handle, context.temp_allocator)
    it := hm.iterator_make(&w.entities)
    for e, h in hm.iterate(&it) {
        if _, has := editor_entity_icon(e); !has do continue
        if linalg.length(e.position - eye) >= EDITOR_ICON_FADE_END && !e.selected do continue
        s, front := ui_world_to_screen(ev, e.position)
        if !front || !on_view(ev, s, 0) do continue
        append(&candidates, h)
    }
    n := len(candidates)
    if n == 0 do return
    for k in 0 ..< min(n, EDITOR_ICON_RAYS_PER_FRAME) {
        h := candidates[(ev.icon_cursor + k) % n]
        e := entity_get(w, h) or_continue
        to := e.position - eye
        dist := linalg.length(to)
        if dist < 1e-4 { ev.icon_hidden[h.idx] = false; continue }
        hit, blocked := pick_entity(w, Ray{origin = eye, dir = to / dist})
        ev.icon_hidden[h.idx] = blocked && hit.entity != h && hit.t < dist - 0.05
    }
    ev.icon_cursor = (ev.icon_cursor + EDITOR_ICON_RAYS_PER_FRAME) % n
}

// Draws every icon in `ev`'s view. Call right after the image item, before the gizmo, so the gizmo
// draws over them.
editor_draw_icons :: proc(ev: ^Editor_View) {
    editor_icons_update_occlusion(ev)
    o := ui_overlay_begin(ev)
    defer ui_overlay_end(o)
    w := ev.view.world
    it := hm.iterator_make(&w.entities)
    for e, h in hm.iterate(&it) {
        ic := editor_icon_of(ev, e) or_continue
        ring: vec4
        if e.selected do ring = h == w.active ? vec4{0.7, 1, 0.7, 1} : vec4{0.15, 0.9, 0.3, 1}
        col := e.light_type != .None ? editor_light_color(e) : vec4{0.9, 0.9, 0.95, 1}
        col.a = ic.alpha
        ui_overlay_icon(o, e.position, ic.icon, col, ring, ic.radius)
    }
}

// The entity whose icon is under screen point `p` (the nearest, if several overlap). Only icons that are
// drawn count; a small one still has a few pixels of slack.
editor_icon_pick :: proc(ev: ^Editor_View, p: vec2) -> (handle: Entity_Handle, ok: bool) {
    best := max(f32)
    it := hm.iterator_make(&ev.view.world.entities)
    for e, _ in hm.iterate(&it) {
        ic := editor_icon_of(ev, e) or_continue
        if d := linalg.length(ic.center - p); d <= max(ic.radius, 7 * app.dispaly_scale) && d < best {
            best, handle, ok = d, ic.handle, true
        }
    }
    return
}

// The screen rect a marquee tests for an entity with an icon but no model (only while it's drawn).
editor_icon_rect :: proc(ev: ^Editor_View, e: ^Entity) -> (lo, hi: vec2, ok: bool) {
    ic := editor_icon_of(ev, e) or_return
    return ic.center - ic.radius, ic.center + ic.radius, true
}

// An unselected shape's colour. Debug lines don't blend, so dimming darkens rather than fades.
EDITOR_SHAPE_DIM :: 0.4

@(private="file")
editor_dim :: proc(c: vec4) -> vec4 {
    return {c.r * EDITOR_SHAPE_DIM, c.g * EDITOR_SHAPE_DIM, c.b * EDITOR_SHAPE_DIM, c.a}
}
