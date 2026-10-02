package blimp

import "common"
import "base:runtime"
import "core:fmt"
import vmem "core:mem/virtual"

@(lua_ffi="Vec2")  vec2 :: common.vec2
@(lua_ffi="Vec3")  vec3 :: common.vec3
@(lua_ffi="Vec4")  vec4 :: common.vec4

@(lua_ffi="IVec2") ivec2 :: common.ivec2
@(lua_ffi="IVec3") ivec3 :: common.ivec3
@(lua_ffi="IVec4") ivec4 :: common.ivec4

uvec2 :: common.uvec2
uvec3 :: common.uvec3
uvec4 :: common.uvec4

@(lua_ffi="Mat3", as="[9]f32")  mat3 :: common.mat3
@(lua_ffi="Mat4", as="[16]f32") mat4 :: common.mat4
@(lua_ffi="Quat", as="[4]f32")  quat :: common.quat

rgb_u8   :: common.rgb_u8  
rgba_u8  :: common.rgba_u8 
rgb_f32  :: common.rgb_f32
rgba_f32 :: common.rgba_f32

irect_from_wh   :: common.irect_from_wh
rect_from_wh    :: common.rect_from_wh

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
contains_all :: common.contains_all
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

frame_allocator :: proc(a: ^App_Allocators) -> runtime.Allocator {
    return {procedure = frame_alloc_proc, data = a}
}

frame_alloc_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode,
                         size, alignment: int, old_mem: rawptr, old_size: int,
                         loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
    a := (^App_Allocators)(data)
    backing := vmem.arena_allocator(&a.frame_arena)
    result, err := backing.procedure(backing.data, mode, size, alignment, old_mem, old_size, loc)
    if err != nil && err != .Mode_Not_Implemented {
        panic(fmt.tprintf("frame arena exhausted: %v (size %d)", err, size), loc)
    }
    return result, err
}