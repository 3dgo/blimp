package blimp

import "core:math"
import "core:math/linalg"
import hm "core:container/handle_map"
import im "lib:odin-imgui"

// The editor's camera work on a view's free camera (Camera, render_camera.odin), top to bottom:
//   Placing     where a new view looks from, and F's framing
//   Moves       the orbit and zoom steps every control is built from
//   Navigation  mouse and keyboard → those moves (Editor_View.nav)
// The renderer only reads the result.

/* --------------------------------- Placing --------------------------------- */

// The angle a new view looks from (camera_frame_world).
CAMERA_DEFAULT :: Camera {
    yaw       = -math.PI / 4,   // the old {2,2,-2} → origin diagonal
    pitch     = -0.61547970,    // -asin(1/sqrt(3))
    distance  = 3.4641016,      // sqrt(12)
    fov_y     = 1.5707963,
    near      = 0.1,
}

// A new view starts this fraction of the distance that fits everything: a level's bounds include its whole
// ground, so the full fit leaves what's on it small. F still fits everything.
CAMERA_OPEN_DISTANCE_SCALE :: 0.5

// A camera on the default diagonal, aimed at the centre of everything in `w`, at CAMERA_OPEN_DISTANCE_SCALE
// of the distance where the bounding sphere fits the vertical FOV. Used when a world gets a new view.
camera_frame_world :: proc(w: ^World) -> Camera {
    lo := vec3{ max(f32), max(f32), max(f32) }
    hi := vec3{ min(f32), min(f32), min(f32) }
    found := false
    it := hm.iterator_make(&w.entities)
    for e, _ in hm.iterate(&it) do found |= entity_grow_bounds(e, &lo, &hi)

    cam := CAMERA_DEFAULT
    if found {
        camera_fit_bounds(&cam, lo, hi)
        cam.distance *= CAMERA_OPEN_DISTANCE_SCALE
    }
    return cam
}

// F: re-aim the view at its world's selection (or the whole world when nothing is selected), keeping
// the current orientation — only the pivot and distance change.
editor_frame_selection :: proc(ev: ^Editor_View) {
    w := ev.view.world
    lo := vec3{ max(f32), max(f32), max(f32) }
    hi := vec3{ min(f32), min(f32), min(f32) }
    found := false
    any_selected := selection_count(w) > 0
    it := hm.iterator_make(&w.entities)
    for e, _ in hm.iterate(&it) do if e.selected || !any_selected do found |= entity_grow_bounds(e, &lo, &hi)
    if found do camera_fit_bounds(&ev.view.camera, lo, hi)
}

// Pivot on the box centre, pulled back so its bounding sphere fits the vertical FOV.
camera_fit_bounds :: proc(c: ^Camera, lo, hi: vec3) {
    radius := max(linalg.length(hi - lo) * 0.5, 0.5)
    c.pivot    = (lo + hi) * 0.5
    c.distance = radius / math.sin(c.fov_y * 0.5)
}

// Grows lo/hi by the world AABB of the entity's transformed model box. False if it has no model.
entity_grow_bounds :: proc(e: ^Entity, lo, hi: ^vec3) -> bool {
    model, ok := asset_system.models[e.model]
    if !ok {
        // No model: a camera or light still has a place worth framing.
        if e.camera_type == .None && e.light_type == .None do return false
        lo^ = linalg.min(lo^, e.position - 0.5)
        hi^ = linalg.max(hi^, e.position + 0.5)
        return true
    }
    mlo, mhi := model_bounds(model)
    M := entity_transform(e)
    for i in 0 ..< 8 {
        corner := vec3{ (i & 1) != 0 ? mhi.x : mlo.x, (i & 2) != 0 ? mhi.y : mlo.y, (i & 4) != 0 ? mhi.z : mlo.z }
        p := transform_point(M, corner)
        lo^ = {min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)}
        hi^ = {max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)}
    }
    return true
}

/* ---------------------------------- Moves ---------------------------------- */

CAMERA_PITCH_LIMIT  :: 1.55     // radians, just short of straight up/down so +Y stays a valid up
CAMERA_MIN_DISTANCE :: 0.05
CAMERA_ZOOM_STEP    :: 0.15     // fraction of the pivot distance per zoom step (a wheel notch)
CAMERA_ZOOM_MIN     :: 0.1      // smallest distance per step, so zoom never stalls near the pivot

// Turns the view: yaw right, pitch up (radians). Pitch stops just short of vertical.
camera_rotate :: proc(c: ^Camera, yaw, pitch: f32) {
    c.yaw  += yaw
    c.pitch = clamp(c.pitch + pitch, -CAMERA_PITCH_LIMIT, CAMERA_PITCH_LIMIT)
}

// Dolly toward the pivot by `steps` zoom steps (negative: away), each a fraction of the distance.
// Once the distance bottoms out the pivot is pushed forward instead, so you can keep zooming
// through a scene rather than getting stuck.
camera_zoom :: proc(c: ^Camera, steps: f32) {
    c.distance -= steps * max(c.distance * CAMERA_ZOOM_STEP, CAMERA_ZOOM_MIN)
    if c.distance < CAMERA_MIN_DISTANCE {
        c.pivot += camera_forward(c^) * (CAMERA_MIN_DISTANCE - c.distance)
        c.distance = CAMERA_MIN_DISTANCE
    }
}

/* -------------------------------- Navigation -------------------------------- */
// Unity-style viewport controls:
//   Alt + LMB drag  orbit around the pivot
//   Alt + RMB drag  zoom (right / up = in)
//   MMB drag        pan, grabbing the surface under the cursor (nav_pan_depth)
//   wheel           zoom toward the pivot
//   F               frame the selection (editor_frame_selection, from ui_handle_shortcuts)
//   RMB hold        fly: mouse look, WASD move, Q/E down/up, Shift ×2, wheel changes fly speed
//   RMB click       (released without flying) the context menu: ev.context_click, handled by the UI

// The gesture moving a view's camera, if any. Not a camera: what the mouse is doing to one. It starts only
// on a press over the view, then keeps going until that button is released, even off the window.
Nav_Drag :: enum u8 { None, Orbit, Zoom, Pan, Fly }

// A view's navigation state (Editor_View.nav).
Editor_Nav :: struct {
    drag:       Nav_Drag,   // the gesture in progress
    pan_depth:  f32,        // view depth the MMB pan grabbed at its press (nav_pan_depth)
    fly_travel: f32,        // mouse pixels moved during this RMB hold
    fly_moved:  bool,       // WASD/QE moved the camera during this RMB hold
    fly_speed:  f32,        // units per second while flying (RMB + WASD); the wheel adjusts it mid-flight
}

NAV_CLICK_PX       :: 4        // an RMB hold moving less than this (and not flying with keys) is a click

NAV_LOOK_SPEED     :: 0.004    // radians per pixel, for both orbit and fly look
NAV_ZOOM_DRAG      :: 0.02     // zoom steps per pixel of Alt+RMB drag
NAV_FLY_SPEED      :: 5        // a new view's fly speed, units per second
NAV_FLY_SPEED_MIN  :: 0.25
NAV_FLY_SPEED_MAX  :: 200
NAV_FLY_WHEEL      :: 1.2      // fly speed multiplier per wheel notch
NAV_FLY_BOOST      :: 2        // Shift

// Called from the view's window right after its image item (so `ev.hovered` is current).
editor_navigate :: proc(ev: ^Editor_View) {
    c  := &ev.view.camera
    io := ui.io
    ev.context_click = false

    if ev.nav.drag == .None && ev.hovered {
        switch {
        case io.KeyAlt && im.IsMouseClicked(.Left):  ev.nav.drag = .Orbit
        case io.KeyAlt && im.IsMouseClicked(.Right): ev.nav.drag = .Zoom   // before plain RMB = fly
        case im.IsMouseClicked(.Middle):             ev.nav.drag = .Pan
        case im.IsMouseClicked(.Right):              ev.nav.drag = .Fly
        }
        if ev.nav.drag != .None {
            im.SetWindowFocus()   // right/middle clicks don't focus a window on their own
            active_view = ev.view
            ev.nav.fly_travel, ev.nav.fly_moved = 0, false
        }
        if ev.nav.drag == .Pan do ev.nav.pan_depth = nav_pan_depth(ev)
    }

    switch ev.nav.drag {
    case .None:
        if ev.hovered && io.MouseWheel != 0 do camera_zoom(c, io.MouseWheel)

    case .Orbit:
        if !im.IsMouseDown(.Left) { ev.nav.drag = .None; break }
        nav_look(c, io.MouseDelta)

    case .Zoom:
        if !im.IsMouseDown(.Right) { ev.nav.drag = .None; break }
        camera_zoom(c, (io.MouseDelta.x - io.MouseDelta.y) * NAV_ZOOM_DRAG)

    case .Pan:
        if !im.IsMouseDown(.Middle) { ev.nav.drag = .None; break }
        // Scale so the point grabbed at the press stays under the cursor.
        units_per_px := 2 * ev.nav.pan_depth * math.tan(c.fov_y * 0.5) / max(ev.screen_size.y, 1)
        fwd   := camera_forward(c^)
        right := linalg.normalize(linalg.cross(vec3{0, 1, 0}, fwd))
        up    := linalg.cross(fwd, right)
        c.pivot += (-io.MouseDelta.x * right + io.MouseDelta.y * up) * units_per_px

    case .Fly:
        if !im.IsMouseDown(.Right) {
            ev.context_click = ev.hovered && !ev.nav.fly_moved && ev.nav.fly_travel < NAV_CLICK_PX * app.dispaly_scale
            ev.nav.drag = .None
            break
        }
        ev.nav.fly_travel += linalg.length(io.MouseDelta)
        // Look turns around the eye, not the pivot: keep the eye fixed and re-seat the pivot ahead.
        eye := camera_eye(c^)
        nav_look(c, io.MouseDelta)
        fwd := camera_forward(c^)

        if io.MouseWheel != 0 {
            ev.nav.fly_speed = clamp(ev.nav.fly_speed * math.pow(NAV_FLY_WHEEL, io.MouseWheel), NAV_FLY_SPEED_MIN, NAV_FLY_SPEED_MAX)
        }

        right := linalg.normalize(linalg.cross(vec3{0, 1, 0}, fwd))
        move: vec3
        if im.IsKeyDown(.W) do move += fwd
        if im.IsKeyDown(.S) do move -= fwd
        if im.IsKeyDown(.D) do move += right
        if im.IsKeyDown(.A) do move -= right
        if im.IsKeyDown(.E) do move.y += 1
        if im.IsKeyDown(.Q) do move.y -= 1
        if move != 0 {
            ev.nav.fly_moved = true
            speed := ev.nav.fly_speed * (io.KeyShift ? NAV_FLY_BOOST : 1)
            eye += linalg.normalize(move) * speed * io.DeltaTime
        }
        c.pivot = eye + fwd * c.distance
    }
}

// How deep (along the view direction) the pan grabs: the surface under the cursor, as in Max or Houdini,
// so panning moves what you pressed on exactly with the mouse at any distance. Empty space falls back
// to the pivot, the Maya/Blender/Unity behaviour.
@(private="file")
nav_pan_depth :: proc(ev: ^Editor_View) -> f32 {
    c := ev.view.camera
    mp := im.GetMousePos()
    ray := camera_ray(c, mp.x - ev.screen_min.x, mp.y - ev.screen_min.y, ev.screen_size.x, ev.screen_size.y)
    hit, ok := pick_entity(ev.view.world, ray)
    if !ok do return c.distance
    return max(linalg.dot(hit.point - camera_eye(c), camera_forward(c)), c.near)
}

// Mouse motion → view turn: right turns right, up looks up.
@(private="file")
nav_look :: proc(c: ^Camera, delta: [2]f32) {
    camera_rotate(c, delta.x * NAV_LOOK_SPEED, -delta.y * NAV_LOOK_SPEED)
}
