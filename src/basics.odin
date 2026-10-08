package blimp

import "common"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:sync"
import "core:thread"

@(lua_ffi="Vec2")  vec2 :: common.vec2
@(lua_ffi="Vec3")  vec3 :: common.vec3
@(lua_ffi="Vec4")  vec4 :: common.vec4

@(lua_ffi="IVec2") ivec2 :: common.ivec2
@(lua_ffi="IVec3") ivec3 :: common.ivec3
@(lua_ffi="IVec4") ivec4 :: common.ivec4

uvec2 :: common.uvec2
uvec3 :: common.uvec3

@(lua_ffi="Mat3", as="[9]f32")  mat3 :: common.mat3
@(lua_ffi="Mat4", as="[16]f32") mat4 :: common.mat4
@(lua_ffi="Quat", as="[4]f32")  quat :: common.quat

rgba_f32 :: common.rgba_f32

// A small inline string buffer. `[dynamic; N]u8` stores its bytes inside the struct
// and is inline-addressed (slicing recomputes the pointer from the value's own
// address), so it copies by value and is memcpy-safe — no allocation, no lifetime to
// track. That makes it a good fit for strings stored by value (e.g. in the entity
// handle map). Fixed capacity: sbuf_set truncates past it. 64 / 128 / 256 bytes.
sbuf64  :: common.sbuf64
sbuf128 :: common.sbuf128
sbuf256 :: common.sbuf256

sbuf_set :: common.sbuf_set
sbuf_str :: common.sbuf_str

// Reflection access to an inline text field held in an `any` (serializer, inspector, Lua accessors).
// Typed code uses the generic sbuf_set/sbuf_str ($N known at compile time); these are for where the
// field only arrives as an `any`, so the size is a runtime fact. They read it from the type info —
// a [dynamic; N]u8 is { data: [N]u8, len: int }, with `capacity` and `len_offset` in its type info —
// so one path serves every size: a new sbuf size needs no code here.
@(private="file")
sbuf_any_info :: proc(v: any) -> (info: runtime.Type_Info_Fixed_Capacity_Dynamic_Array, ok: bool) {
    info = runtime.type_info_base(type_info_of(v.id)).variant.(runtime.Type_Info_Fixed_Capacity_Dynamic_Array) or_return
    return info, info.elem.id == u8
}

sbuf_any_str :: proc(v: any) -> (text: string, ok: bool) {
    info := sbuf_any_info(v) or_return
    n := (^int)(uintptr(v.data) + info.len_offset)^
    return string((cast([^]u8)v.data)[:n]), true
}

sbuf_any_set :: proc(v: any, s: string) -> bool {
    info := sbuf_any_info(v) or_return
    n := common.utf8_fit_len(s, info.capacity)
    copy((cast([^]u8)v.data)[:n], s[:n])
    (^int)(uintptr(v.data) + info.len_offset)^ = n
    return true
}

sbuf_any_cap :: proc(v: any) -> int {
    info := sbuf_any_info(v) or_else {}
    return info.capacity
}

Ray :: common.Ray

/* ------------------------------- Containers ------------------------------- */
contains :: common.contains
keys :: common.keys
values :: common.values

/* ---------------------------------- Math ---------------------------------- */
look_at_matrix :: common.look_at_matrix
perspective_projection :: common.perspective_projection
perspective_projection_reverse_z :: common.perspective_projection_resverse_z
orthographic_projection :: common.orthographic_projection

transform_point :: common.transform_point
transform_dir :: common.transform_dir

ray_triangle :: common.ray_triangle

/* ------------------------------- Allocators ------------------------------- */
Panic_On_Fail :: struct {
    backing: runtime.Allocator
}

panic_on_fail_allocator :: proc(p: ^Panic_On_Fail) -> runtime.Allocator {
    return runtime.Allocator {
        procedure = panic_on_fail_proc,
        data = p,
    }
}

panic_on_fail_proc :: proc(
    allocator_data: rawptr,
    mode: runtime.Allocator_Mode,
    size, alignment: int,
    old_memory: rawptr,
    old_size: int,
    loc := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
    p := (^Panic_On_Fail)(allocator_data)
    data, err := p.backing.procedure(
        p.backing.data, mode, size, alignment, old_memory, old_size, loc,
    )
    if err != nil && err != .Mode_Not_Implemented {
        buf: [256]byte
        panic(fmt.bprintf(buf[:], "allocation failed: %v (size %d)", err, size), loc)
    }
    return data, err
}

// One colour channel between sRGB (display) encoding and linear: the exact piecewise curve, as the GPU's
// _SRGB formats decode it and the tonemap pass encodes it.
srgb_to_linear :: proc(c: f32) -> f32 {
    return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4)
}

linear_to_srgb :: proc(c: f32) -> f32 {
    return c <= 0.0031308 ? c * 12.92 : 1.055 * math.pow(c, 1.0 / 2.4) - 0.055
}

/* ------------------------------- Threads ------------------------------- */
PARALLEL_CHUNK :: 16   // indices a worker claims at a time

@(private="file")
Parallel_Job :: struct {
    next:  int,   // the first index nobody has claimed yet (atomic)
    count: int,
    data:  rawptr,
    body:  proc(data: rawptr, i: int),
}

// Runs body(data, i) for every i in [0, count) on every core and returns once all are done: one thread
// per core, this one included, each claiming PARALLEL_CHUNK indices at a time off a shared counter, so
// uneven work (a probe near many lights) doesn't leave cores idle. Threads start and stop per call.
// Workers run with a fresh context — their own temp allocator, no logger — so body shouldn't log or
// touch the caller's allocators. `spare_cores` leaves that many cores to other threads (a background
// caller leaves the main thread one). Returns the thread count.
parallel_for :: proc(count: int, data: rawptr, body: proc(data: rawptr, i: int), spare_cores := 0) -> (threads: int) {
    job := Parallel_Job{count = count, data = data, body = body}
    threads = max(os.get_processor_core_count() - spare_cores, 1)
    workers := make([]^thread.Thread, threads - 1, context.temp_allocator)
    for &t in workers do t = thread.create_and_start_with_poly_data(&job, parallel_worker)
    parallel_worker(&job)
    thread.join_multiple(..workers)
    for t in workers do thread.destroy(t)
    return
}

@(private="file")
parallel_worker :: proc(job: ^Parallel_Job) {
    for {
        start := sync.atomic_add(&job.next, PARALLEL_CHUNK)   // returns the value before the add
        if start >= job.count do return
        for i in start ..< min(start + PARALLEL_CHUNK, job.count) do job.body(job.data, i)
    }
}

// The 8 corners of the box lo..hi under transform M (corner i: x from bit 0, y from bit 1, z from bit 2).
box_corners :: proc(M: mat4, lo, hi: vec3) -> (c: [8]vec3) {
    for i in 0 ..< 8 {
        p := vec3{(i & 1) != 0 ? hi.x : lo.x, (i & 2) != 0 ? hi.y : lo.y, (i & 4) != 0 ? hi.z : lo.z}
        c[i] = transform_point(M, p)
    }
    return
}

// The axis-aligned bounds of the box lo..hi under transform M.
box_transformed_bounds :: proc(M: mat4, lo, hi: vec3) -> (out_lo, out_hi: vec3) {
    out_lo, out_hi = vec3(max(f32)), vec3(min(f32))
    for c in box_corners(M, lo, hi) {
        out_lo = linalg.min(out_lo, c)
        out_hi = linalg.max(out_hi, c)
    }
    return
}

// The 12 edges of a box_corners box, as corner index pairs.
BOX_EDGES :: [12][2]int{{0, 1}, {2, 3}, {4, 5}, {6, 7}, {0, 2}, {1, 3}, {4, 6}, {5, 7}, {0, 4}, {1, 5}, {2, 6}, {3, 7}}

// A unit vector perpendicular to the unit vector `dir` (any one, stable as dir turns): a basis for drawing
// circles and cones around it.
perpendicular :: proc(dir: vec3) -> vec3 {
    return linalg.normalize(linalg.cross(abs(dir.y) < 0.99 ? vec3{0, 1, 0} : vec3{1, 0, 0}, dir))
}
