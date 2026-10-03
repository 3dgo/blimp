package blimp

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import im "lib:odin-imgui"

// Viewport overlay drawing: shapes given in world space, drawn on top of one view's image with ImGui.
// Crisp, any thickness, always in front of the scene, and only in that view. For tools and markers:
// the gizmo, camera/light icons, readouts.
//
// The other layer is render_debug_draw.odin (`debug_line`, `debug_circle`, …): 3D lines drawn in the scene
// pass, depth-tested so geometry hides them, 1px. Use that for things that live in the world (a light's
// reach); use this for things that belong to the editor's view of it.
//
//     o := overlay_begin(ev)          // inside the view's window, after its image (ui_draw_view)
//     defer overlay_end(o)
//     overlay_icon(o, e.position, ICON_CAMERA, {1, 1, 1, 1})
//
// The shapes are what the editor draws: a shaded cone and cube (the gizmo's handles) and an icon (camera
// and light markers). Each skips itself when any part is behind the camera. For anything else, project
// with world_to_screen and draw on o.dl, as the gizmo does.

Overlay :: struct {
    ev: ^Editor_View,
    dl: ^im.DrawList,
}

OVERLAY_CONE_SEGMENTS   :: 16
OVERLAY_ICON_RADIUS     :: 13     // pixels (× display scale): an icon's backing disc

// Starts drawing into `ev`'s view: the current window's draw list, clipped to the view's image.
overlay_begin :: proc(ev: ^Editor_View) -> Overlay {
    o := Overlay{ev, im.GetWindowDrawList()}
    im.DrawList_PushClipRect(o.dl, ev.screen_min, ev.screen_min + ev.screen_size, true)
    return o
}

overlay_end :: proc(o: Overlay) {
    im.DrawList_PopClipRect(o.dl)
}

/* ------------------------------- Projection ------------------------------- */

// The screen point (ImGui coordinates) of world point `p`; false when it's behind the camera.
world_to_screen :: proc(ev: ^Editor_View, p: vec3) -> (vec2, bool) {
    clip := overlay_clip(ev, p)
    if clip.w <= OVERLAY_NEAR_W do return {}, false
    return clip_to_screen(ev, clip), true
}

@(private="file") OVERLAY_NEAR_W :: 1e-5

@(private="file")
overlay_clip :: proc(ev: ^Editor_View, p: vec3) -> vec4 {
    aspect := ev.screen_size.x / max(ev.screen_size.y, 1)
    return camera_proj(ev.view.camera, aspect) * camera_view(ev.view.camera) * vec4{p.x, p.y, p.z, 1}
}

@(private="file")
clip_to_screen :: proc(ev: ^Editor_View, clip: vec4) -> vec2 {
    ndc := clip.xy / clip.w
    return ev.screen_min + {(ndc.x * 0.5 + 0.5) * ev.screen_size.x, (0.5 - ndc.y * 0.5) * ev.screen_size.y}
}

// World units one pixel covers at view depth 1 (it grows linearly with depth): sizing things in world units
// from a pixel size, or back.
overlay_units_per_pixel_at_depth_1 :: proc(ev: ^Editor_View) -> f32 {
    return 2 * math.tan(ev.view.camera.fov_y * 0.5) / max(ev.screen_size.y, 1)
}

// Pixels per world unit at `p`'s depth.
overlay_pixels_per_unit :: proc(ev: ^Editor_View, p: vec3) -> f32 {
    c := ev.view.camera
    depth := linalg.dot(p - camera_eye(c), camera_forward(c))
    if depth <= 1e-4 do return 0
    return 1 / (depth * overlay_units_per_pixel_at_depth_1(ev))
}

/* --------------------------------- Filled --------------------------------- */

// A shaded 3D cone drawn flat: its base circle and apex projected, the silhouette (their convex hull)
// filled with `side`, and the base disc on top in `cap` when the camera looks at its underside.
// `dir` is a unit vector from the base centre toward the apex.
overlay_cone :: proc(o: Overlay, base, dir: vec3, length, radius: f32, side, cap: vec4) {
    u := perpendicular(dir)
    v := linalg.cross(dir, u)
    pts: [OVERLAY_CONE_SEGMENTS + 1]vec2
    for s in 0 ..< OVERLAY_CONE_SEGMENTS {
        t := f32(s) / OVERLAY_CONE_SEGMENTS * math.TAU
        ok: bool
        pts[s], ok = world_to_screen(o.ev, base + (u * math.cos(t) + v * math.sin(t)) * radius)
        if !ok do return
    }
    apex_ok: bool
    pts[OVERLAY_CONE_SEGMENTS], apex_ok = world_to_screen(o.ev, base + dir * length)
    if !apex_ok do return

    hull := convex_hull(pts[:])
    im.DrawList_AddConvexPolyFilled(o.dl, raw_data(hull), i32(len(hull)), u32_color(side))
    if linalg.dot(dir, camera_eye(o.ev.view.camera) - base) < 0 {
        disc := pts[:OVERLAY_CONE_SEGMENTS]
        make_clockwise(disc)
        im.DrawList_AddConvexPolyFilled(o.dl, raw_data(disc), i32(len(disc)), u32_color(cap))
    }
}

// A shaded 3D cube drawn flat: the faces turned toward the camera, each lit by how much it faces a
// light over the camera's shoulder. A box's visible faces never overlap, so they need no sorting.
// `axes` are its unit directions, `half` its half-size.
overlay_cube :: proc(o: Overlay, center: vec3, axes: [3]vec3, half: f32, col: vec4) {
    eye := camera_eye(o.ev.view.camera)
    light := linalg.normalize(linalg.normalize(eye - center) + vec3{0, 0.8, 0})
    for i in 0 ..< 3 do for sign in ([2]f32{1, -1}) {
        n := axes[i] * sign
        if linalg.dot(n, eye - (center + n * half)) <= 0 do continue   // faces away
        u := axes[(i + 1) % 3] * half
        v := axes[(i + 2) % 3] * half
        c := center + n * half
        quad: [4]vec2
        visible := true
        for corner, k in ([4]vec3{c - u - v, c + u - v, c + u + v, c - u + v}) {
            ok: bool
            quad[k], ok = world_to_screen(o.ev, corner)
            visible &&= ok
        }
        if !visible do continue
        shade := 0.45 + 0.55 * max(linalg.dot(n, light), 0)
        make_clockwise(quad[:])
        im.DrawList_AddConvexPolyFilled(o.dl, &quad[0], 4, u32_color({col.r * shade, col.g * shade, col.b * shade, col.a}))
    }
}

/* ------------------------------ Text and icons ----------------------------- */

// A sprite-like marker: an icon-font glyph (editor_icons.odin) on a dark disc at world point `p`. `radius_px`
// sizes the disc (default OVERLAY_ICON_RADIUS) and the glyph scales with it; `col.a` fades the whole
// icon. `ring` (alpha > 0) outlines the disc, e.g. to show selection.
overlay_icon :: proc(o: Overlay, p: vec3, icon: string, col: vec4, ring := vec4{}, radius_px: f32 = 0) {
    s, front := world_to_screen(o.ev, p)
    if !front do return
    full := OVERLAY_ICON_RADIUS * app.display_scale
    r := radius_px > 0 ? radius_px : full
    im.DrawList_AddCircleFilled(o.dl, s, r, u32_color({0.08, 0.08, 0.1, 0.8 * col.a}))
    if ring.a > 0 do im.DrawList_AddCircle(o.dl, s, r, u32_color({ring.r, ring.g, ring.b, ring.a * col.a}), 0, 2 * app.display_scale)
    t := strings.clone_to_cstring(icon, context.temp_allocator)
    k := r / full   // the glyph keeps its proportion to the disc
    size := im.CalcTextSize(t) * k
    im.DrawList_AddTextImFontPtr(o.dl, im.GetFont(), im.GetFontSize() * k, s - size * 0.5, u32_color(col), t)
}

/* --------------------------------- Helpers -------------------------------- */

@(private="file")
u32_color :: proc(c: vec4) -> u32 { return im.ColorConvertFloat4ToU32(c) }

// Convex hull of a few points (Andrew's monotone chain), clockwise on screen (ImGui's anti-aliased
// fill wants that), in temp memory.
@(private="file")
convex_hull :: proc(points: []vec2) -> []vec2 {
    p := make([]vec2, len(points), context.temp_allocator)
    copy(p, points)
    slice.sort_by(p, proc(a, b: vec2) -> bool { return a.x < b.x || (a.x == b.x && a.y < b.y) })
    cross :: proc(o, a, b: vec2) -> f32 { return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
    hull := make([dynamic]vec2, 0, 2 * len(p), context.temp_allocator)
    for pass in 0 ..< 2 {   // lower chain, then upper
        start := len(hull)
        for i in 0 ..< len(p) {
            q := p[i] if pass == 0 else p[len(p) - 1 - i]
            for len(hull) >= start + 2 && cross(hull[len(hull) - 2], hull[len(hull) - 1], q) <= 0 do pop(&hull)
            append(&hull, q)
        }
        pop(&hull)   // the last point starts the other chain
    }
    make_clockwise(hull[:])
    return hull[:]
}

// Screen space is y-down: clockwise on screen ⇔ positive shoelace sum.
@(private="file")
make_clockwise :: proc(poly: []vec2) {
    area: f32
    for i in 0 ..< len(poly) {
        a, b := poly[i], poly[(i + 1) % len(poly)]
        area += a.x * b.y - b.x * a.y
    }
    if area < 0 do slice.reverse(poly)
}
