package blimp

import "core:math"
import "core:math/linalg"
import hm "core:container/handle_map"
import im "lib:odin-imgui"

// The editor's side of a Render_View: where its image sits on screen, mouse interaction in it
// (camera navigation, gizmo, marquee), and window placement. Kept off Render_View so the renderer's
// view stays a target + camera + world. One per view, created on first use, freed when the view
// closes (editor_view_forget from ui_forget_view).
Editor_View :: struct {
    view: ^Render_View,

    // The view's image this frame, in ImGui screen coordinates (set by ui_draw_view). Keyboard
    // actions (paste, remote picks) raycast through it even though they run before that draw.
    screen_min, screen_size: vec2,
    hovered: bool,

    nav:     Camera_Nav,    // the camera drag in progress, if any
    pan_depth:     f32,     // view depth the MMB pan grabbed at its press (nav_pan_depth)
    fly_travel:    f32,     // mouse pixels moved during this RMB hold
    fly_moved:     bool,    // WASD/QE moved the camera during this RMB hold
    context_click: bool,    // this frame: RMB released without flying = a right-click (opens the context menu)
    remote_context: Maybe(vec2),   // a right-click at this view pixel requested by blimpctl `menu`
    gizmo:   Gizmo_State,   // transform gizmo hover/drag (editor_gizmo.odin)
    marquee: struct { pressing, dragging, double: bool, start: vec2 },   // left-press selection in progress (ui_view_selection); double: the press was a double-click
    placed:  bool,          // its window got its first-frame floating placement (ui_next_view_window_placement)
    icon_hidden: [MAX_ENTITIES]bool,   // camera/light icon blocked by geometry, by handle index (editor_icons_update_occlusion)
    icon_cursor: int,                  // where the next frame's icon occlusion rays start
    game_view: bool,                   // G: hide everything editor-only here (icons, outlines, selection boxes, gizmo), like Unreal
    show_probes: bool,                 // draw the world's baked probes as debug spokes (probe_grid_debug_lines)
    collapsed: bool,        // its window was collapsed last frame
    full_size: vec2,        // its window's size while expanded, restored after a collapse (ui_view_window_keep_size)
    restore_frames: int,    // frames left to keep reapplying full_size after an expand
}

@(private="file")
editor_views: [dynamic]^Editor_View   // editor state → general heap; individually allocated, so pointers stay put

// The editor state for `v`, created on first use.
editor_view :: proc(v: ^Render_View) -> ^Editor_View {
    for ev in editor_views do if ev.view == v do return ev
    ev := new(Editor_View)
    ev.view = v
    append(&editor_views, ev)
    return ev
}

editor_view_forget :: proc(v: ^Render_View) {
    for ev, i in editor_views {
        if ev.view != v do continue
        delete(ev.gizmo.members)
        free(ev)
        unordered_remove(&editor_views, i)
        return
    }
}

editor_views_shutdown :: proc() {
    for ev in editor_views { delete(ev.gizmo.members); free(ev) }
    delete(editor_views)
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
// A drag starts only on a press over the viewport, then keeps going until that button is released,
// even if the cursor leaves the window.
Camera_Nav :: enum u8 { None, Orbit, Zoom, Pan, Fly }

NAV_CLICK_PX       :: 4        // an RMB hold moving less than this (and not flying with keys) is a click

NAV_LOOK_SPEED     :: 0.004    // radians per pixel, for both orbit and fly look
NAV_ZOOM_DRAG      :: 0.02     // zoom steps per pixel of Alt+RMB drag
NAV_FLY_SPEED_MIN  :: 0.25
NAV_FLY_SPEED_MAX  :: 200
NAV_FLY_WHEEL      :: 1.2      // fly speed multiplier per wheel notch
NAV_FLY_BOOST      :: 2        // Shift

// Called from the view's window right after its image item (so `ev.hovered` is current).
editor_navigate :: proc(ev: ^Editor_View) {
    c  := &ev.view.camera
    io := ui.io
    ev.context_click = false

    if ev.nav == .None && ev.hovered {
        switch {
        case io.KeyAlt && im.IsMouseClicked(.Left):  ev.nav = .Orbit
        case io.KeyAlt && im.IsMouseClicked(.Right): ev.nav = .Zoom   // before plain RMB = fly
        case im.IsMouseClicked(.Middle):             ev.nav = .Pan
        case im.IsMouseClicked(.Right):              ev.nav = .Fly
        }
        if ev.nav != .None {
            im.SetWindowFocus()   // right/middle clicks don't focus a window on their own
            active_view = ev.view
            ev.fly_travel, ev.fly_moved = 0, false
        }
        if ev.nav == .Pan do ev.pan_depth = nav_pan_depth(ev)
    }

    switch ev.nav {
    case .None:
        if ev.hovered && io.MouseWheel != 0 do camera_zoom(c, io.MouseWheel)

    case .Orbit:
        if !im.IsMouseDown(.Left) { ev.nav = .None; break }
        nav_look(c, io.MouseDelta)

    case .Zoom:
        if !im.IsMouseDown(.Right) { ev.nav = .None; break }
        camera_zoom(c, (io.MouseDelta.x - io.MouseDelta.y) * NAV_ZOOM_DRAG)

    case .Pan:
        if !im.IsMouseDown(.Middle) { ev.nav = .None; break }
        // Scale so the point grabbed at the press stays under the cursor.
        units_per_px := 2 * ev.pan_depth * math.tan(c.fov_y * 0.5) / max(ev.screen_size.y, 1)
        fwd   := camera_forward(c^)
        right := linalg.normalize(linalg.cross(vec3{0, 1, 0}, fwd))
        up    := linalg.cross(fwd, right)
        c.pivot += (-io.MouseDelta.x * right + io.MouseDelta.y * up) * units_per_px

    case .Fly:
        if !im.IsMouseDown(.Right) {
            ev.context_click = ev.hovered && !ev.fly_moved && ev.fly_travel < NAV_CLICK_PX * app.dispaly_scale
            ev.nav = .None
            break
        }
        ev.fly_travel += linalg.length(io.MouseDelta)
        // Look turns around the eye, not the pivot: keep the eye fixed and re-seat the pivot ahead.
        eye := camera_eye(c^)
        nav_look(c, io.MouseDelta)
        fwd := camera_forward(c^)

        if io.MouseWheel != 0 {
            c.fly_speed = clamp(c.fly_speed * math.pow(NAV_FLY_WHEEL, io.MouseWheel), NAV_FLY_SPEED_MIN, NAV_FLY_SPEED_MAX)
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
            ev.fly_moved = true
            speed := c.fly_speed * (io.KeyShift ? NAV_FLY_BOOST : 1)
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

// The view to act in for world `w` (a level or its play copy) from outside any viewport — the entity
// list, the Bake window: the active view when it shows that level, else the first that does. nil if none.
editor_view_for_world :: proc(w: ^World) -> ^Editor_View {
    level := world_level(w)
    if active_view != nil && world_level(active_view.world) == level do return editor_view(active_view)
    for v in views do if world_level(v.world) == level do return editor_view(v)
    return nil
}
