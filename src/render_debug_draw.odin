package blimp

import "dx"
import "core:mem"
import "core:math"
import "core:math/linalg"

MAX_DEBUG_LINE_VERTS :: 65536   // the probe view takes 12 per probe

Debug_Line_Vertex :: struct { pos: vec4, color: vec4 }
#assert(size_of(Debug_Line_Vertex) == 32)

Debug_Draw :: struct {
    verts: [dynamic]Debug_Line_Vertex,
    buffer: [FRAMES_IN_FLIGHT]dx.Resource,
    buffer_ptr: [FRAMES_IN_FLIGHT]rawptr,
    buffer_srv: [FRAMES_IN_FLIGHT]dx.Resource_View,
    pipeline: Shader_Pipeline,
}
debug_draw: Debug_Draw

debug_draw_init :: proc() {
    debug_draw.verts = make([dynamic]Debug_Line_Vertex, 0, MAX_DEBUG_LINE_VERTS, app.allocators.perm)
    for i in 0..<FRAMES_IN_FLIGHT {
        debug_draw.buffer[i] = dx.buffer_create(renderer_dx.render_context,
            {element_size = size_of(Debug_Line_Vertex), num_elements = MAX_DEBUG_LINE_VERTS, heap_type = .UPLOAD})
        debug_draw.buffer_ptr[i] = dx.buffer_map(debug_draw.buffer[i])
        debug_draw.buffer_srv[i] = dx.descriptor_heap_register_srv(renderer_dx.render_context, &renderer_dx.resource_heap, debug_draw.buffer[i])  
    }
    line_opts := dx.PIPELINE_OPTIONS_DEFAULT
    line_opts.topology    = .LINE
    line_opts.cull_mode   = .NONE
    line_opts.depth_test  = false   // tested against the scene's depth in the shader: it's at the scene size, the lines at the display size
    line_opts.depth_write = false
    line_opts.dsv_format  = .UNKNOWN
    debug_draw.pipeline = shader_pipeline_create("debug_line", "vert_main", "frag_main", line_opts)
}

debug_draw_shutdown :: proc() {
    shader_pipeline_destroy(debug_draw.pipeline)
    for i in 0..<FRAMES_IN_FLIGHT {
        dx.descriptor_heap_free(&renderer_dx.resource_heap, debug_draw.buffer_srv[i].heap_slot)
        dx.buffer_unmap(debug_draw.buffer[i])
        dx.buffer_destroy(debug_draw.buffer[i])
    }
    delete(debug_draw.verts)
}

debug_line :: proc(a, b: vec3, color := vec4{1, 1, 1, 1}) {
    if len(debug_draw.verts) + 2 > MAX_DEBUG_LINE_VERTS do return
    append(&debug_draw.verts, Debug_Line_Vertex{{a.x, a.y, a.z, 1}, color})
    append(&debug_draw.verts, Debug_Line_Vertex{{b.x, b.y, b.z, 1}, color})
}

debug_box :: proc(center: vec3, half: vec3, color := vec4{1, 1, 1, 1}) {
    debug_box_corners(box_corners(mat4(1), center - half, center + half), color)
}

// The 12 edges of a box given by its corners (box_corners order): a transformed box.
debug_box_corners :: proc(c: [8]vec3, color := vec4{1, 1, 1, 1}) {
    for e in BOX_EDGES do debug_line(c[e[0]], c[e[1]], color)
}

// A circle in the plane spanned by the unit vectors `a` and `b`.
debug_circle :: proc(center, a, b: vec3, radius: f32, color := vec4{1, 1, 1, 1}, segments := 32) {
    prev := center + a * radius
    for i in 1 ..= segments {
        t := f32(i) / f32(segments) * math.TAU
        next := center + (a * math.cos(t) + b * math.sin(t)) * radius
        debug_line(prev, next, color)
        prev = next
    }
}

// A sphere as three great circles, around `rotation`'s axes.
debug_sphere :: proc(center: vec3, radius: f32, color := vec4{1, 1, 1, 1}, rotation := quat(1)) {
    x, y, z := debug_axes_of(rotation)
    debug_circle(center, x, y, radius, color)
    debug_circle(center, x, z, radius, color)
    debug_circle(center, y, z, radius, color)
}

// A cone from `apex` along the unit `dir`, opening by `half_angle` radians and reaching `length` from
// the apex in every direction, so it's capped by a piece of sphere (what a spot light lights): its rim
// circle, four side lines and two arcs over the cap through the tip. `cap = false` leaves the arcs out,
// for a cone drawn inside another of the same length (their arcs would lie on each other and z-fight).
debug_cone :: proc(apex, dir: vec3, length, half_angle: f32, color := vec4{1, 1, 1, 1}, cap := true) {
    u := perpendicular(dir)
    v := linalg.cross(dir, u)
    debug_circle(apex + dir * (length * math.cos(half_angle)), u, v, length * math.sin(half_angle), color)
    SEGMENTS :: 16
    for side in ([2]vec3{u, v}) {
        prev := apex + (dir * math.cos(half_angle) - side * math.sin(half_angle)) * length
        debug_line(apex, prev, color)
        if !cap {
            debug_line(apex, apex + (dir * math.cos(half_angle) + side * math.sin(half_angle)) * length, color)
            continue
        }
        for i in 1 ..= SEGMENTS {
            t := half_angle * (2 * f32(i) / SEGMENTS - 1)
            next := apex + (dir * math.cos(t) + side * math.sin(t)) * length
            debug_line(prev, next, color)
            prev = next
        }
        debug_line(apex, prev, color)
    }
}

// A cylinder from `base` along unit `dir`: its two end circles and four side lines (what a cylinder
// light lights).
debug_cylinder :: proc(base, dir: vec3, length, radius: f32, color := vec4{1, 1, 1, 1}) {
    u := perpendicular(dir)
    v := linalg.cross(dir, u)
    tip := base + dir * length
    debug_circle(base, u, v, radius, color)
    debug_circle(tip, u, v, radius, color)
    for side in ([4]vec3{u, -u, v, -v}) do debug_line(base + side * radius, tip + side * radius, color)
}

// A line with a two-stroke head, `head` world units long.
debug_arrow :: proc(from, to: vec3, color := vec4{1, 1, 1, 1}, head: f32 = 0.2) {
    debug_line(from, to, color)
    dir := to - from
    if linalg.length(dir) < 1e-5 do return
    dir = linalg.normalize(dir)
    side := perpendicular(dir)
    debug_line(to, to - dir * head + side * head * 0.5, color)
    debug_line(to, to - dir * head - side * head * 0.5, color)
}

// A view volume from `origin`, oriented by `rotation` (+Z forward, +Y up), from `near` to `far` deep,
// with those half-sizes there (equal half-sizes make an orthographic box). A small triangle on top of
// the far end shows which way is up.
debug_frustum :: proc(origin: vec3, rotation: quat, near, far: f32, near_half, far_half: vec2, color := vec4{1, 1, 1, 1}) {
    right, up, forward := debug_axes_of(rotation)
    corners :: proc(c, right, up: vec3, half: vec2) -> [4]vec3 {
        return {c - right * half.x - up * half.y, c + right * half.x - up * half.y,
                c + right * half.x + up * half.y, c - right * half.x + up * half.y}
    }
    n := corners(origin + forward * near, right, up, near_half)
    f := corners(origin + forward * far, right, up, far_half)
    for i in 0 ..< 4 {
        debug_line(n[i], n[(i + 1) % 4], color)
        debug_line(f[i], f[(i + 1) % 4], color)
        debug_line(n[i], f[i], color)
    }
    top := origin + forward * far + up * far_half.y
    debug_line(top - right * far_half.x * 0.3, top + up * far_half.y * 0.3, color)
    debug_line(top + right * far_half.x * 0.3, top + up * far_half.y * 0.3, color)
}

// A rotation's right (+X), up (+Y) and forward (+Z) directions.
debug_axes_of :: proc(rotation: quat) -> (right, up, forward: vec3) {
    return linalg.quaternion_mul_vector3(rotation, vec3{1, 0, 0}),
           linalg.quaternion_mul_vector3(rotation, vec3{0, 1, 0}),
           linalg.quaternion_mul_vector3(rotation, vec3{0, 0, 1})
}

// The frame's lines are one list: each view's editor lines appended as its own range before the frame
// (ui_view_debug_lines). Upload once, then each view draws just its range, then clear.

// Copies this frame's lines into the flight's mapped buffer. Call after every line is appended,
// before the frame is submitted.
debug_draw_upload :: proc(frame_slot: u64) {
    n := min(len(debug_draw.verts), MAX_DEBUG_LINE_VERTS)
    if n > 0 do mem.copy(debug_draw.buffer_ptr[frame_slot], raw_data(debug_draw.verts), n * size_of(Debug_Line_Vertex))
}

// Draws lines [first, first+count) of the uploaded list into the currently bound target, with the
// currently bound view's constants. `first` goes in as StartVertexLocation; the shader adds it via
// SV_StartVertexLocation (D3D's SV_VertexID is 0-based per draw and doesn't include it).
debug_draw_lines :: proc(cmd: dx.Command_List, first, count: u32) {
    if first >= MAX_DEBUG_LINE_VERTS do return
    n := min(count, MAX_DEBUG_LINE_VERTS - first)
    if n == 0 do return
    cmd.handle->SetPipelineState(debug_draw.pipeline.pso.handle)
    cmd.handle->IASetPrimitiveTopology(.LINELIST)
    cmd.handle->DrawInstanced(n, 1, first, 0)
}

debug_draw_clear :: proc() {
    clear(&debug_draw.verts)
}