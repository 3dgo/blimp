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
//     o := ui_overlay_begin(ev)          // inside the view's window, after its image (ui_draw_view)
//     defer ui_overlay_end(o)
//     ui_overlay_line(o, a, b, {1, 0, 0, 1}, 2)
//     ui_overlay_icon(o, e.position, ICON_CAMERA, {1, 1, 1, 1})
//
// Lines are clipped at the camera's near plane, so a segment running behind the camera is cut where it
// crosses it rather than dropped. Filled shapes (disc, cone, cube, icon) skip themselves when any part
// is behind the camera.

UI_Overlay :: struct {
    ev: ^Editor_View,
    dl: ^im.DrawList,
}

UI_OVERLAY_CIRCLE_SEGMENTS :: 48
UI_OVERLAY_CONE_SEGMENTS   :: 16
UI_OVERLAY_ICON_RADIUS     :: 13     // pixels (× display scale): an icon's backing disc

// Starts drawing into `ev`'s view: the current window's draw list, clipped to the view's image.
ui_overlay_begin :: proc(ev: ^Editor_View) -> UI_Overlay {
    o := UI_Overlay{ev, im.GetWindowDrawList()}
    im.DrawList_PushClipRect(o.dl, ev.screen_min, ev.screen_min + ev.screen_size, true)
    return o
}

ui_overlay_end :: proc(o: UI_Overlay) {
    im.DrawList_PopClipRect(o.dl)
}

/* ------------------------------- Projection ------------------------------- */

// The screen point (ImGui coordinates) of world point `p`; false when it's behind the camera.
ui_world_to_screen :: proc(ev: ^Editor_View, p: vec3) -> (vec2, bool) {
    clip := ui_overlay_clip(ev, p)
    if clip.w <= UI_OVERLAY_NEAR_W do return {}, false
    return clip_to_screen(ev, clip), true
}

@(private="file") UI_OVERLAY_NEAR_W :: 1e-5

@(private="file")
ui_overlay_clip :: proc(ev: ^Editor_View, p: vec3) -> vec4 {
    aspect := ev.screen_size.x / max(ev.screen_size.y, 1)
    return camera_proj(ev.view.camera, aspect) * camera_view(ev.view.camera) * vec4{p.x, p.y, p.z, 1}
}

@(private="file")
clip_to_screen :: proc(ev: ^Editor_View, clip: vec4) -> vec2 {
    ndc := clip.xy / clip.w
    return ev.screen_min + {(ndc.x * 0.5 + 0.5) * ev.screen_size.x, (0.5 - ndc.y * 0.5) * ev.screen_size.y}
}

// Pixels per world unit at `p`'s depth: for sizing things in world units from a pixel size, or back.
ui_overlay_pixels_per_unit :: proc(ev: ^Editor_View, p: vec3) -> f32 {
    c := ev.view.camera
    depth := linalg.dot(p - camera_eye(c), camera_forward(c))
    if depth <= 1e-4 do return 0
    return ev.screen_size.y / (2 * depth * math.tan(c.fov_y * 0.5))
}

/* ---------------------------------- Lines --------------------------------- */

ui_overlay_line :: proc(o: UI_Overlay, a, b: vec3, col: vec4, thickness: f32 = 1) {
    ca, cb := ui_overlay_clip(o.ev, a), ui_overlay_clip(o.ev, b)
    if ca.w <= UI_OVERLAY_NEAR_W && cb.w <= UI_OVERLAY_NEAR_W do return
    // One end behind the camera: move it along the segment to where it crosses the near limit.
    if ca.w <= UI_OVERLAY_NEAR_W do ca = linalg.lerp(ca, cb, (UI_OVERLAY_NEAR_W - ca.w) / (cb.w - ca.w) + 1e-4)
    if cb.w <= UI_OVERLAY_NEAR_W do cb = linalg.lerp(cb, ca, (UI_OVERLAY_NEAR_W - cb.w) / (ca.w - cb.w) + 1e-4)
    im.DrawList_AddLine(o.dl, clip_to_screen(o.ev, ca), clip_to_screen(o.ev, cb), u32_color(col), thickness)
}

// A connected line through `points`; `closed` joins the last back to the first.
ui_overlay_polyline :: proc(o: UI_Overlay, points: []vec3, col: vec4, thickness: f32 = 1, closed := false) {
    for i in 1 ..< len(points) do ui_overlay_line(o, points[i - 1], points[i], col, thickness)
    if closed && len(points) > 2 do ui_overlay_line(o, points[len(points) - 1], points[0], col, thickness)
}

// A circle in the plane spanned by the unit vectors `a` and `b`.
ui_overlay_circle :: proc(o: UI_Overlay, center, a, b: vec3, radius: f32, col: vec4, thickness: f32 = 1) {
    prev := center + a * radius
    for i in 1 ..= UI_OVERLAY_CIRCLE_SEGMENTS {
        t := f32(i) / UI_OVERLAY_CIRCLE_SEGMENTS * math.TAU
        next := center + (a * math.cos(t) + b * math.sin(t)) * radius
        ui_overlay_line(o, prev, next, col, thickness)
        prev = next
    }
}

// The 12 edges of a box: `axes` are its (unit) directions, `half` its half-size along each.
ui_overlay_box :: proc(o: UI_Overlay, center: vec3, axes: [3]vec3, half: vec3, col: vec4, thickness: f32 = 1) {
    corner :: proc(center: vec3, axes: [3]vec3, half: vec3, i: int) -> vec3 {
        return center + axes[0] * ((i & 1) != 0 ? half.x : -half.x) + axes[1] * ((i & 2) != 0 ? half.y : -half.y) + axes[2] * ((i & 4) != 0 ? half.z : -half.z)
    }
    edges := [12][2]int{{0, 1}, {2, 3}, {4, 5}, {6, 7}, {0, 2}, {1, 3}, {4, 6}, {5, 7}, {0, 4}, {1, 5}, {2, 6}, {3, 7}}
    for e in edges do ui_overlay_line(o, corner(center, axes, half, e[0]), corner(center, axes, half, e[1]), col, thickness)
}

// A line from `from` to `to` with a two-stroke head, `head` world units long.
ui_overlay_arrow :: proc(o: UI_Overlay, from, to: vec3, col: vec4, thickness: f32 = 1, head: f32 = 0.2) {
    ui_overlay_line(o, from, to, col, thickness)
    dir := to - from
    l := linalg.length(dir)
    if l < 1e-5 do return
    dir /= l
    side := linalg.normalize(linalg.cross(abs(dir.y) < 0.99 ? vec3{0, 1, 0} : vec3{1, 0, 0}, dir))
    ui_overlay_line(o, to, to - dir * head + side * head * 0.5, col, thickness)
    ui_overlay_line(o, to, to - dir * head - side * head * 0.5, col, thickness)
}

/* --------------------------------- Filled --------------------------------- */

// A disc of `radius_px` pixels at world point `p` (a dot that doesn't shrink with distance).
ui_overlay_disc :: proc(o: UI_Overlay, p: vec3, radius_px: f32, col: vec4) {
    s, front := ui_world_to_screen(o.ev, p)
    if !front do return
    im.DrawList_AddCircleFilled(o.dl, s, radius_px, u32_color(col))
}

// A shaded 3D cone drawn flat: its base circle and apex projected, the silhouette (their convex hull)
// filled with `side`, and the base disc on top in `cap` when the camera looks at its underside.
// `dir` is a unit vector from the base centre toward the apex.
ui_overlay_cone :: proc(o: UI_Overlay, base, dir: vec3, length, radius: f32, side, cap: vec4) {
    u := linalg.normalize(linalg.cross(abs(dir.y) < 0.99 ? vec3{0, 1, 0} : vec3{1, 0, 0}, dir))
    v := linalg.cross(dir, u)
    pts: [UI_OVERLAY_CONE_SEGMENTS + 1]vec2
    for s in 0 ..< UI_OVERLAY_CONE_SEGMENTS {
        t := f32(s) / UI_OVERLAY_CONE_SEGMENTS * math.TAU
        ok: bool
        pts[s], ok = ui_world_to_screen(o.ev, base + (u * math.cos(t) + v * math.sin(t)) * radius)
        if !ok do return
    }
    apex_ok: bool
    pts[UI_OVERLAY_CONE_SEGMENTS], apex_ok = ui_world_to_screen(o.ev, base + dir * length)
    if !apex_ok do return

    hull := convex_hull(pts[:])
    im.DrawList_AddConvexPolyFilled(o.dl, raw_data(hull), i32(len(hull)), u32_color(side))
    if linalg.dot(dir, camera_eye(o.ev.view.camera) - base) < 0 {
        disc := pts[:UI_OVERLAY_CONE_SEGMENTS]
        make_clockwise(disc)
        im.DrawList_AddConvexPolyFilled(o.dl, raw_data(disc), i32(len(disc)), u32_color(cap))
    }
}

// A shaded 3D cube drawn flat: the faces turned toward the camera, each lit by how much it faces a
// light over the camera's shoulder. A box's visible faces never overlap, so they need no sorting.
// `axes` are its unit directions, `half` its half-size.
ui_overlay_cube :: proc(o: UI_Overlay, center: vec3, axes: [3]vec3, half: f32, col: vec4) {
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
            quad[k], ok = ui_world_to_screen(o.ev, corner)
            visible &&= ok
        }
        if !visible do continue
        shade := 0.45 + 0.55 * max(linalg.dot(n, light), 0)
        make_clockwise(quad[:])
        im.DrawList_AddConvexPolyFilled(o.dl, &quad[0], 4, u32_color({col.r * shade, col.g * shade, col.b * shade, col.a}))
    }
}

/* ------------------------------ Text and icons ----------------------------- */

// Text at world point `p`, centred on it, nudged by `offset_px`.
ui_overlay_text :: proc(o: UI_Overlay, p: vec3, text: string, col: vec4, offset_px := vec2{0, 0}) {
    s, front := ui_world_to_screen(o.ev, p)
    if !front do return
    t := strings.clone_to_cstring(text, context.temp_allocator)
    im.DrawList_AddText(o.dl, s + offset_px - im.CalcTextSize(t) * 0.5, u32_color(col), t)
}

// A sprite-like marker: an icon-font glyph (editor_icons.odin) on a dark disc at world point `p`. `radius_px`
// sizes the disc (default UI_OVERLAY_ICON_RADIUS) and the glyph scales with it; `col.a` fades the whole
// icon. `ring` (alpha > 0) outlines the disc, e.g. to show selection.
ui_overlay_icon :: proc(o: UI_Overlay, p: vec3, icon: string, col: vec4, ring := vec4{}, radius_px: f32 = 0) {
    s, front := ui_world_to_screen(o.ev, p)
    if !front do return
    full := UI_OVERLAY_ICON_RADIUS * app.dispaly_scale
    r := radius_px > 0 ? radius_px : full
    im.DrawList_AddCircleFilled(o.dl, s, r, u32_color({0.08, 0.08, 0.1, 0.8 * col.a}))
    if ring.a > 0 do im.DrawList_AddCircle(o.dl, s, r, u32_color({ring.r, ring.g, ring.b, ring.a * col.a}), 0, 2 * app.dispaly_scale)
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
