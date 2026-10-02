package blimp

import "core:math"
import "core:math/linalg"
import hm "core:container/handle_map"

// Orbit-style camera: looks at `pivot` from `distance` away along yaw/pitch. Orbit spins around the
// pivot, pan slides it, zoom changes the distance, and fly moves eye and pivot together (the pivot
// rides along `distance` ahead of the eye), so every navigation mode edits the same few numbers.
// World up is always +Y (pitch is clamped short of vertical), so there's no stored up vector.
Camera :: struct {
    pivot:      vec3,
    yaw, pitch: f32,   // radians. yaw 0 looks down +Z, positive turns toward +X; positive pitch looks up
    distance:   f32,   // eye = pivot - forward * distance
    fov_y:      f32,
    near:       f32,
    fly_speed:  f32,   // units per second while flying (RMB + WASD); the wheel adjusts it mid-flight
}

CAMERA_DEFAULT :: Camera {
    yaw       = -math.PI / 4,   // the old {2,2,-2} → origin diagonal
    pitch     = -0.61547970,    // -asin(1/sqrt(3))
    distance  = 3.4641016,      // sqrt(12)
    fov_y     = 1.5707963,
    near      = 0.1,
    fly_speed = 5,
}

CAMERA_PITCH_LIMIT  :: 1.55     // radians, just short of straight up/down so +Y stays a valid up
CAMERA_MIN_DISTANCE :: 0.05
CAMERA_ZOOM_STEP    :: 0.15     // fraction of the pivot distance per zoom step (a wheel notch)
CAMERA_ZOOM_MIN     :: 0.1      // smallest distance per step, so zoom never stalls near the pivot

camera_forward :: proc(c: Camera) -> vec3 {
    cp := math.cos(c.pitch)
    return {cp * math.sin(c.yaw), math.sin(c.pitch), cp * math.cos(c.yaw)}
}

camera_eye :: proc(c: Camera) -> vec3 {
    return c.pivot - camera_forward(c) * c.distance
}

// A camera on the default diagonal, aimed at the centre of everything in `w` and pulled back so the
// bounding sphere fits the vertical FOV. Used when a world gets a new view.
camera_frame_world :: proc(w: ^World) -> Camera {
    lo := vec3{ max(f32), max(f32), max(f32) }
    hi := vec3{ min(f32), min(f32), min(f32) }
    found := false
    it := hm.iterator_make(&w.entities)
    for e, _ in hm.iterate(&it) do found |= entity_grow_bounds(e, &lo, &hi)

    cam := CAMERA_DEFAULT
    if found do camera_fit_bounds(&cam, lo, hi)
    return cam
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

camera_view :: proc(c: Camera) -> mat4 {
    return linalg.inverse(look_at_matrix(camera_eye(c), c.pivot, {0, 1, 0}))
}

camera_proj :: proc(c: Camera, aspect: f32) -> mat4 {
    return perspective_projection_reverse_z(c.fov_y, aspect, c.near)
}

camera_ray :: proc(c: Camera, px, py, width, height: f32) -> Ray {
    aspect := width / height
    tan_half := math.tan(c.fov_y * 0.5)

    ndc_x := 2 * (px + 0.5) / width - 1
    ndc_y := 1 - 2 * (py + 0.5) / height

    dir_view := vec3{ ndc_x * aspect * tan_half, ndc_y * tan_half, 1}

    eye := camera_eye(c)
    cam_to_world := look_at_matrix(eye, c.pivot, {0, 1, 0})
    dir_world := transform_dir(cam_to_world, dir_view)
    return Ray { origin = eye, dir = linalg.normalize(dir_world) }
}

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

// A camera entity's view: its position and rotation (scale ignored), looking down its +Z.
entity_camera_view :: proc(e: ^Entity) -> mat4 {
    return linalg.inverse(linalg.matrix4_from_trs_f32(e.position, e.rotation, 1))
}

// A camera entity's projection, reversed-Z (near and far passed swapped) and clipped to its `range`.
// Ortho height is `size.y`; the aspect comes from the target.
entity_camera_proj :: proc(e: ^Entity, aspect: f32) -> mat4 {
    near, far := e.range.x, e.range.y
    if e.camera_type == .Orthographic {
        h := e.size.y * 0.5
        return orthographic_projection(-h * aspect, h * aspect, -h, h, far, near)
    }
    return perspective_projection(math.to_radians(e.fov), aspect, far, near)
}
