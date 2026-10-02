package common

/* ----------------------------------- vec ---------------------------------- */
vec2 :: [2]f32
vec3 :: [3]f32
vec4 :: [4]f32

ivec2 :: [2]i32
ivec3 :: [3]i32
ivec4 :: [4]i32

uvec2 :: [2]u32
uvec3 :: [3]u32
uvec4 :: [4]u32

/* ---------------------------------- rect ---------------------------------- */
rect :: struct {tl: vec2, br: vec2}
urect :: struct {tl: uvec2, br: uvec2}
irect :: struct {tl: ivec2, br: ivec2}

frect_from_wh :: proc(tl: vec2, wh: vec2) -> rect {return {tl = tl, br = tl + wh}}
urect_from_wh :: proc(tl: uvec2, wh: uvec2) -> urect {return {tl = tl, br = tl + wh}}
irect_from_wh :: proc(tl: ivec2, wh: ivec2) -> irect {return {tl = tl, br = tl + wh}}
rect_from_wh :: proc {frect_from_wh, urect_from_wh, irect_from_wh}

/* --------------------------------- matrix --------------------------------- */
mat3 :: matrix[3, 3]f32
mat4 :: matrix[4, 4]f32

/* ------------------------------- quaternion ------------------------------- */
quat :: quaternion128

/* ---------------------------------- color --------------------------------- */
rgb_u8 :: [3]u8
rgba_u8 :: [4]u8
rgb_f32 :: [3]f32
rgba_f32 :: [4]f32

/* ---------------------------------- sbuf ---------------------------------- */
// Inline owned text, sized by what it holds. Pick the smallest that fits — every byte lives in the
// struct (and in every copy of it).
sbuf64  :: [dynamic; 64]u8    // names, ids, gameplay tags
sbuf128 :: [dynamic; 128]u8   // short free text: labels, captions
sbuf256 :: [dynamic; 256]u8   // long owned text: paths, descriptions

// Sets an inline text buffer of any capacity, truncating past it on a UTF-8 boundary (never mid-char).
sbuf_set :: proc(b: ^[dynamic; $N]u8, s: string) {
    clear(b)
    n := utf8_fit_len(s, N)
    #no_bounds_check for i in 0..<n do append(b, s[i])
}

// How many leading bytes of `s` fit in `max` bytes without splitting a multi-byte UTF-8 char.
utf8_fit_len :: proc(s: string, max: int) -> int {
    n := min(len(s), max)
    for n > 0 && n < len(s) && (s[n] & 0xC0) == 0x80 do n -= 1
    return n
}

sbuf_str :: proc(b: ^[dynamic; $N]u8) -> string {
    return string(b[:])
}

/* ----------------------------------- ray ---------------------------------- */
Ray :: struct {
    origin: vec3,
    dir: vec3,
}