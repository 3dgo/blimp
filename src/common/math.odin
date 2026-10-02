package common
import "core:math"
import la "core:math/linalg"

look_at_matrix :: proc(eye: la.Vector3f32, target: la.Vector3f32, arbitrary_up: la.Vector3f32) -> matrix[4, 4]f32 {
    forward := la.normalize(target - eye)
    right := la.normalize(la.cross(arbitrary_up, forward))
    up := la.cross(forward, right)

    mat_rot: matrix[4, 4]f32 = {
        right.x, up.x, forward.x, 0,
        right.y, up.y, forward.y, 0,
        right.z, up.z, forward.z, 0,
        0,       0,    0,         1}
        
    mat_tran: matrix[4, 4]f32 = {
        1, 0, 0, eye.x,
        0, 1, 0, eye.y,
        0, 0, 1, eye.z,
        0, 0, 0, 1}
    
    mat_look := mat_tran * mat_rot

    return mat_look
}

perspective_projection :: proc(fovy: f32, aspect: f32, near: f32, far: f32) -> matrix[4, 4]f32 {
    tan_half_fovy := math.tan(fovy * 0.5)
    
    proj: matrix[4, 4]f32 = 0
    proj[0, 0] = 1.0 / (aspect * tan_half_fovy)
    proj[1, 1] = 1.0 / tan_half_fovy
    proj[2, 2] = far / (far - near)
    proj[3, 2] = 1.0
    proj[2, 3] = (-near * far) / (far - near)
   
    return proj
}

perspective_projection_resverse_z :: proc(fovy: f32, aspect: f32, near: f32) -> matrix[4, 4]f32 {
    tan_half_fovy := math.tan(fovy * 0.5)
    
    proj: matrix[4, 4]f32 = 0
    proj[0, 0] = 1.0 / (aspect * tan_half_fovy)
    proj[1, 1] = 1.0 / tan_half_fovy
    proj[2, 2] = 0
    proj[3, 2] = 1.0
    proj[2, 3] = near
   
    return proj
}

orthographic_projection :: proc(left, right, bottom, top, near, far: f32) -> matrix[4, 4]f32 {
    m: matrix[4, 4]f32 = 0	
    m[0, 0] = +2 / (right - left)
	m[1, 1] = +2 / (top - bottom)
	m[2, 2] = +1 / (far - near)
	m[0, 3] = -(right + left)   / (right - left)
	m[1, 3] = -(top + bottom) / (top - bottom)
	m[2, 3] = -near / (far- near)
	m[3, 3] = 1

    return m
}

transform_point :: proc(m: mat4, p: vec3) -> vec3 { r := m * vec4{p.x, p.y, p.z, 1}; return {r.x, r.y, r.z} }
transform_dir :: proc(m: mat4, d: vec3) -> vec3 {r := m * vec4{d.x, d.y, d.z, 0}; return {r.x, r.y, r.z} }

ray_triangle :: proc(r: Ray, v0, v1, v2: vec3) -> (t: f32, hit: bool) {
    EPS :: 1e-8
    e1 := v1 - v0
    e2 := v2 - v0
    p  := la.cross(r.dir, e2)
    det := la.dot(e1, p)
    if abs(det) < EPS do return 0, false
    inv := 1.0 / det

    tv := r.origin - v0
    u := la.dot(tv, p) * inv
    if u < 0 || u > 1 do return 0, false

    q := la.cross(tv, e1)
    v := la.dot(r.dir, q) * inv
    if v < 0 || u + v > 1 do return 0, false

    t = la.dot(e2, q) * inv
    if t <= EPS do return 0, false
    return t, true
}