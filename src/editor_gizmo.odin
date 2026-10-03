package blimp

import "core:fmt"
import "core:math"
import "core:math/linalg"
import im "lib:odin-imgui"

// Transform gizmo for the selected entity, laid out like 3ds Max: Select shows a passive X/Y/Z
// tripod; Move has labelled axes, L-bracket plane handles and a centre square (move in the ev
// plane); Rotate has the three axis rings plus an outer ev ring; Scale has axes with end boxes and
// a centre square (uniform). Drawn with the viewport window's ImGui draw list rather than debug
// lines, so it sits on top of the scene (debug lines are depth-tested). Hit-testing is in screen space.
//
// Dragging keeps the grabbed point under the cursor:
//   - axis handles: the mouse is projected onto the axis' screen line, and the ray through that
//     point meets the axis exactly — motion along the axis tracks the cursor 1:1, motion across it
//     is ignored (a raw closest-point-to-ray lets sideways motion leak in, badly when the axis
//     points toward the camera)
//   - planes, the ev-plane square, and rings: the mouse ray against their plane, exact by construction
//
// Space: Global uses world axes, Local the entity's own (from its rotation at drag start, so the
// rings don't turn under the cursor mid-rotate). Scale is always local — scale is applied before
// rotation, so world-axis scale handles would stretch the wrong way on a rotated entity.
//
// Snapping (toolbar toggle; Ctrl held inverts it): move snaps to the world grid in Global (kit
// pieces line up) and the displacement in Local, rotate snaps the swept angle, scale the value.
Edit_Tool :: enum u8 { Select, Move, Rotate, Scale }

Gizmo_Space :: enum u8 { Global, Local }

// What rotate and scale turn about when several entities are selected (3ds Max's pivot modes).
// Selection_Center: one pivot at the centre of the selection's combined bounds — the selection turns
// and scales as a group (positions change). Individual_Pivots: each entity about its own pivot
// (positions stay). Move is the same in both; the mode also places the gizmo.
Gizmo_Pivot :: enum u8 { Selection_Center, Individual_Pivots }

// X/Y/Z: the axes (rotate: the rings around them). YZ/XZ/XY: move planes, named by the two axes they
// span. Center: move in the ev plane (the centre square), rotate around the ev axis (the outer
// ring), uniform scale (the centre square).
Gizmo_Handle :: enum u8 { None, X, Y, Z, YZ, XZ, XY, Center }

Gizmo_State :: struct {
    hot:   Gizmo_Handle,   // under the mouse this frame
    drag:  Gizmo_Handle,   // being dragged; .None = idle
    start: Entity,         // the drag's reference transform: the active entity's rotation + scale at the pivot's position
    grab_rel: vec3,        // move: that point relative to the pivot, in gizmo lengths (see gizmo_follow)
    grab_s: f32,           // scale: grab distance along the axis
    grab_mouse: vec2,      // uniform scale: mouse position at drag start
    stretch: vec3,         // scale: how far each drawn axis is stretched by the drag (3ds Max style; back to 1 on release)
    view_axis: vec3,       // rotate Center: the ev direction at drag start (the camera can't move mid-drag, but be exact)
    angle_last, angle_total: f32,   // rotate: last ring angle, and the unwrapped angle swept since the grab
    pushed: bool,          // undo snapshot taken (on first actual change, so a click is no step)
    readout: sbuf64,       // what the current drag has done ("X +1.250", "Y +45.0°"), shown by the gizmo
    members: [dynamic]Gizmo_Member,   // every selected entity at drag start (the active one included); heap, kept across drags
    draw_origin: vec3,                // where the gizmo is drawn mid-drag (the pivot, carried along by a move)
}

// A selected entity's transform at drag start. The drag computes the active entity's new transform,
// then applies the same change to each member (move: same offset; rotate: same rotation, each about
// its own pivot; scale: same factor per local axis).
Gizmo_Member :: struct {
    handle:   Entity_Handle,
    position: vec3,
    rotation: quat,
    scale:    vec3,
}

Gizmo_Snap :: struct {
    enabled: bool,
    move:    f32,   // grid step, world units
    angle:   f32,   // degrees
    scale:   f32,
}
GIZMO_SNAP_DEFAULT :: Gizmo_Snap{move = 0.5, angle = 15, scale = 0.1}

GIZMO_SIZE_PX      :: 80     // on-screen axis length / ring radius (× display scale)
GIZMO_THICKNESS    :: 2.5
GIZMO_HIT_PX       :: 8.5    // grab distance from a line or ring (× display scale)
GIZMO_GRAB_GROW    :: 1.2    // handle grab areas are this much bigger than drawn (planes, centre cube), so near-misses count
GIZMO_GRAB_REACH   :: 1.1    // axis grab runs this far along the axis (past the cone tip)
GIZMO_PLANE_LO     :: 0.0    // move plane handle square, as fractions of the axis length (Unity: at the centre)
GIZMO_PLANE_HI     :: 0.25
GIZMO_CONE_LEN     :: 0.22   // move arrowhead cone, as fractions of the axis length
GIZMO_CONE_RADIUS  :: 0.065
GIZMO_CUBE_HALF    :: 0.055  // scale end cube half-size, as a fraction of the axis length
GIZMO_CENTER_CUBE_HALF :: 0.075   // the centre (uniform scale) cube
GIZMO_CENTER_PX    :: 6      // grab half-size of the centre cube (uniform scale)
GIZMO_VIEW_RING    :: 1.25   // rotate ev ring radius, × the axis ring radius
GIZMO_LABEL_PX     :: 10     // axis label distance past the tip
GIZMO_RING_SEGMENTS :: 64
GIZMO_UNIFORM_PX_PER_X :: 100    // uniform scale: pixels of drag per 1.0 of scale factor
GIZMO_MIN_SCALE    :: 0.01   // negative scale would flip triangle winding (and culling)

@(private="file") WORLD_AXES  := [3]vec3{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}
@(private="file") AXIS_NAMES  := [3]cstring{"X", "Y", "Z"}
@(private="file") AXIS_COLORS := [3]vec4{{0.95, 0.25, 0.25, 1}, {0.4, 0.9, 0.25, 1}, {0.3, 0.5, 1, 1}}
@(private="file") HOT_COLOR   := vec4{1, 0.85, 0.1, 1}
@(private="file") VIEW_COLOR  := vec4{0.75, 0.75, 0.75, 1}

// Runs inside the ev's window right after its image item. Returns true when the gizmo owns the
// mouse this frame (hovered or dragging), so the caller skips click-picking.
gizmo_update :: proc(ev: ^Editor_View, tool: Edit_Tool, space: Gizmo_Space, pivot_mode: Gizmo_Pivot, snap: Gizmo_Snap) -> bool {
    g := &ev.gizmo
    g.hot = .None
    w := ev.view.world
    // The gizmo acts on the whole selection. Its axes come from the active entity; it sits on the
    // pivot the mode picks — the selection centre, or the active entity's own pivot.
    e, ok := entity_get(w, editor_world(w).active)
    if !ok || tool == .Select {
        g.drag = .None
        if ok do gizmo_draw(ev, .Select, e.position, gizmo_axes(.Select, space, e.rotation), gizmo_world_length(ev, e.position))
        return false
    }
    pivot := e.position
    if pivot_mode == .Selection_Center do pivot = selection_center(w)

    m := im.GetMousePos()
    mouse := vec2{m.x, m.y}

    if g.drag != .None {
        // The drag's frame of reference is fixed at its start.
        axes := gizmo_axes(tool, space, g.start.rotation)
        if im.IsKeyPressed(.Escape, false) {   // cancel: back to where it started, no undo step
            if g.pushed {
                undo_revert_last()   // restores the pre-drag snapshot and drops it
            } else {
                // No snapshot (a play world keeps no undo): put the members back from their start.
                for mb in g.members {
                    me := entity_get(w, mb.handle) or_continue
                    me.position, me.rotation, me.scale = mb.position, mb.rotation, mb.scale
                }
            }
            g.drag = .None
        } else if !im.IsMouseDown(.Left) {
            g.drag = .None
        } else {
            target, moved := gizmo_drag(ev, g, tool, space, axes, mouse, snap.enabled != im.GetIO().KeyCtrl, snap)
            changed := target.position != g.start.position || target.rotation != g.start.rotation || target.scale != g.start.scale
            if moved && (changed || g.pushed) {   // once the drag has changed anything, keep applying (even back to no change)
                if !g.pushed {
                    // One undo step for the whole drag. Nothing has moved yet, so this snapshot is the
                    // pre-drag state.
                    g.pushed = undo_push(w)   // false in a play world: no undo there
                }
                gizmo_apply(w, g, tool, pivot_mode, axes, target)
            }
        }
        g.hot = g.drag
    } else if ev.hovered && ev.nav.drag == .None && !im.GetIO().KeyAlt {
        axes := gizmo_axes(tool, space, e.rotation)
        g.hot = gizmo_hit_test(ev, tool, pivot, axes, gizmo_world_length(ev, pivot), mouse)
        if g.hot != .None && im.IsMouseClicked(.Left) do gizmo_begin(ev, g, tool, e^, pivot, axes, mouse)
    }

    // Drawn at the pivot (mid-drag: where the drag has carried it), with the active entity's axes as they are now.
    if g.drag != .None do pivot = g.draw_origin
    gizmo_draw(ev, tool, pivot, gizmo_axes(tool, space, e.rotation), gizmo_world_length(ev, pivot))
    return g.hot != .None
}

/* --------------------------------- Dragging -------------------------------- */

@(private="file")
// `e` is the active entity; `pivot` is where the gizmo sits. The drag works on a reference transform
// (g.start): the active entity's rotation and scale (axes, scale snapping) at the pivot's position.
gizmo_begin :: proc(ev: ^Editor_View, g: ^Gizmo_State, tool: Edit_Tool, e: Entity, pivot: vec3, axes: [3]vec3, mouse: vec2) -> (started: bool) {
    h := g.hot
    e := e
    e.position = pivot
    switch tool {
    case .Select:
        return false
    case .Move:
        grab := gizmo_project(ev, h, e.position, axes, mouse) or_return   // where the cursor met the axis/plane
        g.grab_rel = (grab - e.position) / gizmo_world_length(ev, e.position)
    case .Rotate:
        g.view_axis = linalg.normalize(e.position - camera_eye(ev.view.camera))
        angle := gizmo_ring_angle(ev, gizmo_ring_frame(axes, h, g.view_axis), e.position, mouse) or_return
        g.angle_last, g.angle_total = angle, 0
    case .Scale:
        if h == .Center {
            g.grab_mouse = mouse
        } else {
            p := gizmo_project(ev, h, e.position, axes, mouse) or_return
            g.grab_s = linalg.dot(p - e.position, axes[gizmo_axis_index(h)])
            if abs(g.grab_s) < 1e-4 do return false
        }
    }
    g.drag, g.start, g.pushed = h, e, false
    g.draw_origin = pivot
    clear(&g.members)
    for sh in selection_handles(ev.view.world) {
        if m, mok := entity_get(ev.view.world, sh); mok do append(&g.members, Gizmo_Member{sh, m.position, m.rotation, m.scale})
    }
    sbuf_set(&g.readout, "")
    g.stretch = 1
    return true
}

// The dragged entity's new transform, computed from its state at drag start (so snapping and
// cancelling never accumulate error), and the readout describing it. Not ok on a frame where the
// cursor is degenerate for the handle (keep the current transform).
@(private="file")
gizmo_drag :: proc(ev: ^Editor_View, g: ^Gizmo_State, tool: Edit_Tool, space: Gizmo_Space, axes: [3]vec3, mouse: vec2, snapping: bool, snap: Gizmo_Snap) -> (target: Entity, ok: bool) {
    target = g.start
    switch tool {
    case .Select:
    case .Move:
        p := gizmo_project(ev, g.drag, g.start.position, axes, mouse) or_return
        delta := gizmo_follow(ev, p, g.grab_rel) - g.start.position
        if snapping && snap.move > 0 {
            if space == .Global {
                // Snap the result onto the world grid, on the dragged axes only (a constrained move
                // never jumps off its line/plane).
                pos := g.start.position + delta
                for i in 0 ..< 3 do if gizmo_handle_moves_axis(g.drag, i) do pos[i] = math.round(pos[i] / snap.move) * snap.move
                delta = pos - g.start.position
            } else {
                // Local axes aren't grid-aligned: snap the displacement along each dragged axis.
                snapped: vec3
                for i in 0 ..< 3 {
                    if !gizmo_handle_moves_axis(g.drag, i) do continue
                    d := linalg.dot(delta, axes[i])
                    snapped += axes[i] * (math.round(d / snap.move) * snap.move)
                }
                delta = snapped
            }
        }
        target.position = g.start.position + delta
        #partial switch g.drag {
        case .X, .Y, .Z:
            i := gizmo_axis_index(g.drag)
            gizmo_readout(g, "%s %+.3f", AXIS_NAMES[i], linalg.dot(delta, axes[i]))
        case:
            gizmo_readout(g, "%+.3f, %+.3f, %+.3f  (%.3f)", delta.x, delta.y, delta.z, linalg.length(delta))
        }
    case .Rotate:
        frame := gizmo_ring_frame(axes, g.drag, g.view_axis)
        if angle, hit := gizmo_ring_angle(ev, frame, g.start.position, mouse); hit {
            d := angle - g.angle_last
            if d >  math.PI do d -= 2 * math.PI   // unwrap across ±π so whole turns accumulate
            if d < -math.PI do d += 2 * math.PI
            g.angle_total += d
            g.angle_last = angle
        }
        a := g.angle_total
        if snapping && snap.angle > 0 {
            step := math.to_radians(snap.angle)
            a = math.round(a / step) * step
        }
        // frame.n is the world direction of the ring's axis (global, start-local, or ev), so one
        // formula serves every ring.
        target.rotation = linalg.normalize(linalg.quaternion_angle_axis(a, frame.n) * g.start.rotation)
        name := g.drag == .Center ? cstring("View") : AXIS_NAMES[gizmo_axis_index(g.drag)]
        gizmo_readout(g, "%s %+.1f°", name, math.to_degrees(a))
    case .Scale:
        if g.drag == .Center {
            f := 1 + ((mouse.x - g.grab_mouse.x) - (mouse.y - g.grab_mouse.y)) / GIZMO_UNIFORM_PX_PER_X
            if snapping && snap.scale > 0 do f = math.round(f / snap.scale) * snap.scale
            f = max(f, GIZMO_MIN_SCALE)
            target.scale = g.start.scale * f
            g.stretch = f
            gizmo_readout(g, "×%.3f", f)
        } else {
            i := gizmo_axis_index(g.drag)
            p := gizmo_project(ev, g.drag, g.start.position, axes, mouse) or_return
            s := g.start.scale[i] * linalg.dot(p - g.start.position, axes[i]) / g.grab_s
            if snapping && snap.scale > 0 do s = math.round(s / snap.scale) * snap.scale
            target.scale[i] = max(s, GIZMO_MIN_SCALE)
            g.stretch = 1
            g.stretch[i] = target.scale[i] / g.start.scale[i]
            gizmo_readout(g, "%s %.3f  (×%.3f)", AXIS_NAMES[i], target.scale[i], target.scale[i] / g.start.scale[i])
        }
    }
    return target, true
}

@(private="file")
gizmo_readout :: proc(g: ^Gizmo_State, format: string, args: ..any) {
    sbuf_set(&g.readout, fmt.tprintf(format, ..args))
}

// Where the cursor meets handle `h`'s constraint through `origin`. Axis: the mouse projected onto the
// axis' screen line, then the ray through that point meets the axis (exactly, up to float error).
// Plane / Center: the mouse ray's hit on the plane (Center: the ev plane). Fails when degenerate
// (axis seen end-on, plane edge-on), where a tiny mouse move would fling the entity.
@(private="file")
gizmo_project :: proc(ev: ^Editor_View, h: Gizmo_Handle, origin: vec3, axes: [3]vec3, mouse: vec2) -> (p: vec3, ok: bool) {
    #partial switch h {
    case .X, .Y, .Z:
        a := axes[gizmo_axis_index(h)]
        o2 := world_to_screen(ev, origin) or_return
        t2 := world_to_screen(ev, origin + a * gizmo_world_length(ev, origin)) or_return
        d2 := t2 - o2
        len2 := linalg.dot(d2, d2)
        if len2 < 4 do return   // under 2 px on screen: seen end-on
        on_line := o2 + d2 * (linalg.dot(mouse - o2, d2) / len2)
        ray := view_mouse_ray(ev, on_line)
        // Closest point on line origin + s·a to the ray (both unit length); they intersect here.
        wv := origin - ray.origin
        b := linalg.dot(a, ray.dir)
        denom := 1 - b * b
        if denom < 1e-6 do return
        s := (b * linalg.dot(ray.dir, wv) - linalg.dot(a, wv)) / denom
        return origin + a * s, true
    case .YZ, .XZ, .XY:
        return ray_plane(view_mouse_ray(ev, mouse), origin, axes[int(h) - int(Gizmo_Handle.YZ)])   // normal: the axis it leaves out
    case .Center:
        return ray_plane(view_mouse_ray(ev, mouse), origin, camera_forward(ev.view.camera))
    }
    return
}

// A rotate ring: its axis n (world direction) and u, v spanning its plane with v = n × u.
@(private="file")
Ring_Frame :: struct { n, u, v: vec3, radius: f32 }   // radius: × the axis ring radius

@(private="file")
gizmo_ring_frame :: proc(axes: [3]vec3, h: Gizmo_Handle, view_axis: vec3) -> Ring_Frame {
    if h == .Center {
        n := view_axis
        u := perpendicular(n)
        return {n, u, linalg.cross(n, u), GIZMO_VIEW_RING}
    }
    i := gizmo_axis_index(h)
    return {axes[i], axes[(i + 1) % 3], linalg.cross(axes[i], axes[(i + 1) % 3]), 1}
}

// Angle of the cursor's hit on the ring's plane, measured from u toward v — the same sense as
// quaternion_angle_axis(·, n), so the entity turns with the cursor.
@(private="file")
gizmo_ring_angle :: proc(ev: ^Editor_View, f: Ring_Frame, origin: vec3, mouse: vec2) -> (angle: f32, ok: bool) {
    hit := ray_plane(view_mouse_ray(ev, mouse), origin, f.n) or_return
    d := hit - origin
    return math.atan2(linalg.dot(d, f.v), linalg.dot(d, f.u)), true
}

@(private="file")
ray_plane :: proc(ray: Ray, origin, n: vec3) -> (vec3, bool) {
    dn := linalg.dot(ray.dir, n)
    if abs(dn) < 1e-3 do return {}, false
    t := linalg.dot(origin - ray.origin, n) / dn
    if t <= 0 do return {}, false
    return ray.origin + ray.dir * t, true
}

/* ------------------------------ Hit test / draw ----------------------------- */

@(private="file")
gizmo_hit_test :: proc(ev: ^Editor_View, tool: Edit_Tool, origin: vec3, axes: [3]vec3, length: f32, mouse: vec2) -> Gizmo_Handle {
    o, ook := world_to_screen(ev, origin)
    if !ook do return .None
    s := app.display_scale
    best, best_d := Gizmo_Handle.None, f32(GIZMO_HIT_PX) * s
    center_r := (GIZMO_CENTER_PX * GIZMO_GRAB_GROW + 2) * s
    in_center := abs(mouse.x - o.x) <= center_r && abs(mouse.y - o.y) <= center_r

    switch tool {
    case .Select:
    case .Move:
        // Planes before axes: their squares sit at the centre where the axes start. Handles faded out
        // (seen end-on / edge-on) can't be grabbed — there a tiny mouse move would fling the entity.
        for i in 0 ..< 3 {
            if gizmo_plane_alpha(ev, origin, axes[i]) < 0.5 do continue
            q, ok := gizmo_plane_quad(ev, origin, axes, length, i)
            if ok && point_in_quad(mouse, quad_grow(q, GIZMO_GRAB_GROW, 2 * s)) do return Gizmo_Handle(int(Gizmo_Handle.YZ) + i)
        }
        for i in 0 ..< 3 {
            if gizmo_axis_alpha(ev, origin, axes[i], length) < 0.5 do continue
            tip, tok := world_to_screen(ev, origin + axes[i] * (length * GIZMO_GRAB_REACH))   // a little past the cone's apex
            if !tok do continue
            if d := dist_to_segment(mouse, o, tip); d < best_d do best, best_d = Gizmo_Handle(int(Gizmo_Handle.X) + i), d
        }
    case .Scale:
        if in_center do return .Center
        for i in 0 ..< 3 {
            tip, tok := world_to_screen(ev, origin + axes[i] * (length * GIZMO_GRAB_REACH))   // a little past the cube
            if !tok do continue
            if d := dist_to_segment(mouse, o, tip); d < best_d do best, best_d = Gizmo_Handle(int(Gizmo_Handle.X) + i), d
        }
    case .Rotate:
        view_axis := linalg.normalize(origin - camera_eye(ev.view.camera))
        for h in ([]Gizmo_Handle{.X, .Y, .Z, .Center}) {
            pts, front := gizmo_ring_points(ev, gizmo_ring_frame(axes, h, view_axis), origin, length)
            for s in 0 ..< GIZMO_RING_SEGMENTS {
                if !front[s] do continue   // the far half is behind the gizmo; grab the near one
                if d := dist_to_segment(mouse, pts[s], pts[s + 1]); d < best_d do best, best_d = h, d
            }
        }
    }
    return best
}

@(private="file")
gizmo_draw :: proc(ev: ^Editor_View, tool: Edit_Tool, origin: vec3, axes: [3]vec3, length: f32) {
    o, ok := world_to_screen(ev, origin)
    if !ok do return
    ov := overlay_begin(ev)   // editor_overlay.odin
    defer overlay_end(ov)
    dl := ov.dl

    g := &ev.gizmo
    // Lit handles draw yellow: the one hovered or dragged, plus what it moves — a plane lights the two
    // axes it spans, uniform scale lights all three (Unity). While dragging, everything unlit greys out.
    lit: [Gizmo_Handle]bool
    if active := g.drag != .None ? g.drag : g.hot; active != .None {
        lit[active] = true
        #partial switch active {
        case .YZ, .XZ, .XY:
            for i in 0 ..< 3 do if gizmo_handle_moves_axis(active, i) do lit[Gizmo_Handle(int(Gizmo_Handle.X) + i)] = true
        case .Center:
            if tool == .Scale do lit[.X], lit[.Y], lit[.Z] = true, true, true
        }
    }
    color_v :: proc(g: ^Gizmo_State, lit: ^[Gizmo_Handle]bool, h: Gizmo_Handle, base: vec4, alpha: f32 = 1) -> vec4 {
        c := lit[h] ? HOT_COLOR : base
        if g.drag != .None && !lit[h] do c = {0.6, 0.6, 0.6, 0.35}
        c.a *= alpha
        return c
    }
    color :: proc(g: ^Gizmo_State, lit: ^[Gizmo_Handle]bool, h: Gizmo_Handle, base: vec4, alpha: f32 = 1) -> u32 {
        return im.ColorConvertFloat4ToU32(color_v(g, lit, h, base, alpha))
    }
    axis_handle :: proc(i: int) -> Gizmo_Handle { return Gizmo_Handle(int(Gizmo_Handle.X) + i) }

    // Axis lines with X/Y/Z labels past the tip (Select, Scale; Move draws Unity-style arrows below).
    // Mid scale-drag the axes stretch with the scale, like 3ds Max.
    tips: [3]vec2
    tip_ok: [3]bool
    if tool == .Select || tool == .Scale {
        thickness := tool == .Select ? f32(1.5) : GIZMO_THICKNESS
        for i in 0 ..< 3 {
            axis_len := length
            if tool == .Scale && ev.gizmo.drag != .None do axis_len *= ev.gizmo.stretch[i]
            tips[i], tip_ok[i] = world_to_screen(ev, origin + axes[i] * axis_len)
            if !tip_ok[i] do continue
            col := color(g, &lit, axis_handle(i), AXIS_COLORS[i])
            im.DrawList_AddLine(dl, o, tips[i], col, thickness)
            dir := tips[i] - o
            l := linalg.length(dir)
            if l <= 1 do continue
            dir /= l
            label_gap := GIZMO_LABEL_PX * app.display_scale
            label_size := im.CalcTextSize(AXIS_NAMES[i])
            im.DrawList_AddText(dl, tips[i] + dir * label_gap - label_size * 0.5, col, AXIS_NAMES[i])
        }
    }

    switch tool {
    case .Select:   // the tripod above is all; it's informational, not grabbable
    case .Move:
        // Unity's layout: small plane squares at the centre (in the camera-facing quadrant, tinted
        // with their normal axis' colour), then thin axis lines ending in 3D cones, plus our X/Y/Z
        // labels past the tips. Handles fade out as they turn end-on / edge-on.
        for i in 0 ..< 3 {
            a := gizmo_plane_alpha(ev, origin, axes[i])
            if a <= 0 do continue
            q := gizmo_plane_quad(ev, origin, axes, length, i) or_continue
            h := Gizmo_Handle(int(Gizmo_Handle.YZ) + i)
            im.DrawList_AddQuadFilled(dl, q[0], q[1], q[2], q[3], color(g, &lit, h, AXIS_COLORS[i], (lit[h] ? 0.55 : 0.3) * a))
            im.DrawList_AddQuad(dl, q[0], q[1], q[2], q[3], color(g, &lit, h, AXIS_COLORS[i], a), 1.5)
        }
        for i in 0 ..< 3 {
            a := gizmo_axis_alpha(ev, origin, axes[i], length)
            if a <= 0 do continue
            h := axis_handle(i)
            side := color_v(g, &lit, h, AXIS_COLORS[i], a)
            col  := im.ColorConvertFloat4ToU32(side)
            cone_base := origin + axes[i] * (length * (1 - GIZMO_CONE_LEN))
            b2 := world_to_screen(ev, cone_base) or_continue
            im.DrawList_AddLine(dl, o, b2, col, 2)
            cap := vec4{side.r * 0.55, side.g * 0.55, side.b * 0.55, side.a}   // the base disc: darker, highlighted or not
            overlay_cone(ov, cone_base, axes[i], length * GIZMO_CONE_LEN, length * GIZMO_CONE_RADIUS, side, cap)
            tip := world_to_screen(ev, origin + axes[i] * length) or_continue
            if dir := tip - o; linalg.length(dir) > 1 {
                label_size := im.CalcTextSize(AXIS_NAMES[i])
                at := tip + linalg.normalize(dir) * GIZMO_LABEL_PX * app.display_scale - label_size * 0.5
                im.DrawList_AddText(dl, at, col, AXIS_NAMES[i])
            }
        }
    case .Rotate:
        view_axis := linalg.normalize(origin - camera_eye(ev.view.camera))
        for h in ([]Gizmo_Handle{.X, .Y, .Z, .Center}) {
            pts, front := gizmo_ring_points(ev, gizmo_ring_frame(axes, h, view_axis), origin, length)
            base := h == .Center ? VIEW_COLOR : AXIS_COLORS[gizmo_axis_index(h)]
            for s in 0 ..< GIZMO_RING_SEGMENTS {   // far half dimmed and thin, so the near half reads
                if front[s] do im.DrawList_AddLine(dl, pts[s], pts[s + 1], color(g, &lit, h, base), GIZMO_THICKNESS)
                else        do im.DrawList_AddLine(dl, pts[s], pts[s + 1], color(g, &lit, h, base, 0.25), 1)
            }
        }
        im.DrawList_AddCircleFilled(dl, o, 3, 0xFFFFFFFF)
    case .Scale:
        // Unity's cubes: one at each (stretched) axis end, oriented with the axes, and a grey one at the centre.
        for i in 0 ..< 3 {
            axis_len := length * (g.drag != .None ? g.stretch[i] : 1)
            // Outer face at the axis end, so Scale reaches exactly as far as Move and clears the label.
            overlay_cube(ov, origin + axes[i] * (axis_len - length * GIZMO_CUBE_HALF), axes, length * GIZMO_CUBE_HALF, color_v(g, &lit, axis_handle(i), AXIS_COLORS[i]))
        }
        overlay_cube(ov, origin, axes, length * GIZMO_CENTER_CUBE_HALF, color_v(g, &lit, .Center, {0.75, 0.75, 0.75, 1}))
    }

    // While dragging: what the drag has done so far, on a dark plate below-right of the centre.
    if ev.gizmo.drag != .None {
        text := fmt.ctprintf("%s", sbuf_str(&ev.gizmo.readout))
        size := im.CalcTextSize(text)
        pos := o + vec2{14, 14} * app.display_scale
        pad := vec2{4, 2} * app.display_scale
        im.DrawList_AddRectFilled(dl, pos - pad, pos + size + pad, im.ColorConvertFloat4ToU32({0, 0, 0, 0.7}), 3)
        im.DrawList_AddText(dl, pos, 0xFFFFFFFF, text)
    }
}

/* --------------------------------- Helpers --------------------------------- */

// World directions of the gizmo's axes. `rotation` is the entity's — current while idle, at drag start while dragging.
@(private="file")
gizmo_axes :: proc(tool: Edit_Tool, space: Gizmo_Space, rotation: quat) -> [3]vec3 {
    if tool != .Scale && space == .Global do return WORLD_AXES
    return {
        linalg.quaternion_mul_vector3(rotation, WORLD_AXES[0]),
        linalg.quaternion_mul_vector3(rotation, WORLD_AXES[1]),
        linalg.quaternion_mul_vector3(rotation, WORLD_AXES[2]),
    }
}

@(private="file")
gizmo_axis_index :: proc(h: Gizmo_Handle) -> int { return int(h) - int(Gizmo_Handle.X) }

@(private="file")
gizmo_handle_moves_axis :: proc(h: Gizmo_Handle, axis: int) -> bool {
    #partial switch h {
    case .X, .Y, .Z:    return gizmo_axis_index(h) == axis
    case .YZ, .XZ, .XY: return int(h) - int(Gizmo_Handle.YZ) != axis   // a plane moves the two axes it spans
    case .Center:       return true
    }
    return false
}

// Screen points of a ring (closed: the last repeats the first), and per segment whether it's on the
// camera's side of the gizmo centre (always, for the ev ring, which faces the camera).
@(private="file")
gizmo_ring_points :: proc(ev: ^Editor_View, f: Ring_Frame, origin: vec3, length: f32) -> (pts: [GIZMO_RING_SEGMENTS + 1]vec2, front: [GIZMO_RING_SEGMENTS]bool) {
    radius := length * f.radius
    to_eye := camera_eye(ev.view.camera) - origin
    for s in 0 ..= GIZMO_RING_SEGMENTS {
        t := f32(s) / GIZMO_RING_SEGMENTS * 2 * math.PI
        p := origin + (f.u * math.cos(t) + f.v * math.sin(t)) * radius
        pts[s], _ = world_to_screen(ev, p)
        if s < GIZMO_RING_SEGMENTS {
            mid := t + math.PI / GIZMO_RING_SEGMENTS
            front[s] = linalg.dot(f.u * math.cos(mid) + f.v * math.sin(mid), to_eye) >= -1e-4 * linalg.length(to_eye)
        }
    }
    return
}

// World length that projects to GIZMO_SIZE_PX at `p`'s depth, so the gizmo keeps its screen size.
@(private="file")
gizmo_world_length :: proc(ev: ^Editor_View, p: vec3) -> f32 {
    c := ev.view.camera
    depth := linalg.dot(p - camera_eye(c), camera_forward(c))
    return gizmo_length_per_depth(ev) * max(depth, c.near)
}

// The gizmo's world length per unit of view depth (it's linear in depth).
@(private="file")
gizmo_length_per_depth :: proc(ev: ^Editor_View) -> f32 {
    return GIZMO_SIZE_PX * app.display_scale * overlay_units_per_pixel_at_depth_1(ev)
}

// Where the pivot must go so the grabbed point of the gizmo lands on `p` (the cursor's point on the
// drag constraint). The gizmo keeps its screen size, so its world size changes as the entity moves
// in depth; keeping only the grabbed world point under the cursor would let the handle you're
// holding slide away from it — worst when dragging along the view direction. With the grab stored in
// gizmo lengths (g_rel) and length L = k·depth(pivot):  pivot + g_rel·L = p, depth linear in pivot  →
//   L = k·depth(p) / (1 + k·(g_rel·fwd)),   pivot = p − g_rel·L
@(private="file")
gizmo_follow :: proc(ev: ^Editor_View, p, g_rel: vec3) -> vec3 {
    c := ev.view.camera
    k := gizmo_length_per_depth(ev)
    fwd := camera_forward(c)
    denom := max(1 + k * linalg.dot(g_rel, fwd), 0.1)   // only near 0 for a grab far behind the pivot in depth
    L := k * linalg.dot(p - camera_eye(c), fwd) / denom
    return p - g_rel * L
}

// Screen corners of the move plane handle that leaves out axis `skip`: q[0] at the inner corner,
// q[1] out along the next axis, q[2] the outer corner, q[3] out along the one after. Like Unity's,
// the square sits in the quadrant facing the camera, so it never hides behind the entity.
@(private="file")
gizmo_plane_quad :: proc(ev: ^Editor_View, origin: vec3, axes: [3]vec3, length: f32, skip: int) -> (q: [4]vec2, ok: bool) {
    to_eye := camera_eye(ev.view.camera) - origin
    u := axes[(skip + 1) % 3] * length
    v := axes[(skip + 2) % 3] * length
    if linalg.dot(u, to_eye) < 0 do u = -u
    if linalg.dot(v, to_eye) < 0 do v = -v
    corners := [4]vec3{
        origin + u * GIZMO_PLANE_LO + v * GIZMO_PLANE_LO,
        origin + u * GIZMO_PLANE_HI + v * GIZMO_PLANE_LO,
        origin + u * GIZMO_PLANE_HI + v * GIZMO_PLANE_HI,
        origin + u * GIZMO_PLANE_LO + v * GIZMO_PLANE_HI,
    }
    for c, i in corners do q[i] = world_to_screen(ev, c) or_return
    return q, true
}

// Distance from point p to the segment a..b, in screen pixels.
@(private="file")
dist_to_segment :: proc(p, a, b: vec2) -> f32 {
    ab := b - a
    t := clamp(linalg.dot(p - a, ab) / max(linalg.dot(ab, ab), 1e-6), 0, 1)
    return linalg.length(p - (a + ab * t))
}

// Convex quad, either winding: inside when every edge sees p on the same side.
@(private="file")
point_in_quad :: proc(p: vec2, q: [4]vec2) -> bool {
    pos, neg := false, false
    for i in 0 ..< 4 {
        a, b := q[i], q[(i + 1) % 4]
        cr := (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
        if cr > 0 do pos = true
        if cr < 0 do neg = true
    }
    return !(pos && neg)
}

// Applies the active entity's dragged transform to every member, as the same change from its own
// drag-start transform.
@(private="file")
gizmo_apply :: proc(w: ^World, g: ^Gizmo_State, tool: Edit_Tool, pivot_mode: Gizmo_Pivot, axes: [3]vec3, target: Entity) {
    o := g.start.position   // the pivot
    d_pos := target.position - o
    d_rot := target.rotation * linalg.quaternion_inverse(g.start.rotation)
    f: vec3 = 1
    for i in 0 ..< 3 do if g.start.scale[i] != 0 do f[i] = target.scale[i] / g.start.scale[i]
    about_center := pivot_mode == .Selection_Center
    for m in g.members {
        e := entity_get(w, m.handle) or_continue
        switch tool {
        case .Select:
        case .Move:
            e.position = m.position + d_pos
        case .Rotate:
            e.rotation = linalg.normalize(d_rot * m.rotation)
            if about_center do e.position = o + linalg.quaternion_mul_vector3(d_rot, m.position - o)   // orbit the pivot too
        case .Scale:
            e.scale = linalg.max(m.scale * f, vec3(GIZMO_MIN_SCALE))
            if about_center {   // spread or gather around the pivot along the gizmo axes
                off := m.position - o
                scaled: vec3
                for i in 0 ..< 3 do scaled += axes[i] * (linalg.dot(off, axes[i]) * f[i])
                e.position = o + scaled
            }
        }
    }
    g.draw_origin = tool == .Move ? o + d_pos : o
}

// How visible a move axis is: 1 normally, fading to 0 as it turns end-on to the camera (its screen
// length shrinks), where Unity hides it — dragging along it there would be all jitter.
@(private="file")
gizmo_axis_alpha :: proc(ev: ^Editor_View, origin, axis: vec3, length: f32) -> f32 {
    o, ook := world_to_screen(ev, origin)
    t, tok := world_to_screen(ev, origin + axis * length)
    if !ook || !tok do return 0
    r := linalg.length(t - o) / (GIZMO_SIZE_PX * app.display_scale)
    return clamp((r - 0.12) / 0.15, 0, 1)
}

// How visible a move plane square is: fades to 0 as the plane turns edge-on to the camera.
@(private="file")
gizmo_plane_alpha :: proc(ev: ^Editor_View, origin, normal: vec3) -> f32 {
    facing := abs(linalg.dot(normal, linalg.normalize(camera_eye(ev.view.camera) - origin)))
    return clamp((facing - 0.08) / 0.15, 0, 1)
}

// A screen quad scaled about its centre by `k` and pushed out by `margin` pixels (a forgiving grab area).
@(private="file")
quad_grow :: proc(q: [4]vec2, k, margin: f32) -> (out: [4]vec2) {
    c := (q[0] + q[1] + q[2] + q[3]) * 0.25
    for p, i in q {
        d := (p - c) * k
        if l := linalg.length(d); l > 1e-3 do d += d / l * margin
        out[i] = c + d
    }
    return
}
