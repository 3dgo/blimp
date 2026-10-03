package blimp

import "core:math"
import "core:math/linalg"

// A view's free camera (Render_View.camera; a game view renders through a camera entity instead, below).
// Orbit-style: looks at `pivot` from `distance` away along yaw/pitch, so every editor navigation mode edits
// the same few numbers (editor_camera.odin). World up is always +Y (pitch is kept short of
// vertical), so there's no stored up vector. Here: what rendering and picking need from it.
Camera :: struct {
    pivot:      vec3,
    yaw, pitch: f32,   // radians. yaw 0 looks down +Z, positive turns toward +X; positive pitch looks up
    distance:   f32,   // eye = pivot - forward * distance
    fov_y:      f32,
    near:       f32,
}

camera_forward :: proc(c: Camera) -> vec3 {
    cp := math.cos(c.pitch)
    return {cp * math.sin(c.yaw), math.sin(c.pitch), cp * math.cos(c.yaw)}
}

camera_eye :: proc(c: Camera) -> vec3 {
    return c.pivot - camera_forward(c) * c.distance
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
