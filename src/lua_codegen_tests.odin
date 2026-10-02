package blimp


@(lua=zh_add, lua_zh="相加", table=CodegenTest) cg_test_zh_add :: proc(a: f32, b: f32) -> f32 { return a + b }

// --- Primitives ---
@(lua=add_f32,     table=CodegenTest) cg_test_add_f32     :: proc(a: f32, b: f32) -> f32  { return a + b }
@(lua=add_int,     table=CodegenTest) cg_test_add_int     :: proc(a: int, b: int) -> int  { return a + b }
@(lua=negate_bool, table=CodegenTest) cg_test_negate_bool :: proc(b: bool) -> bool        { return !b }
@(lua=echo_string, table=CodegenTest) cg_test_echo_string :: proc(s: string) -> string    { return s }

// --- FFI param -> primitive return ---
@(lua=vec3_lensq,      table=CodegenTest) cg_test_vec3_lensq      :: proc(v: vec3)  -> f32 { return v.x*v.x + v.y*v.y + v.z*v.z }
@(lua=ivec2_manhattan, table=CodegenTest) cg_test_ivec2_manhattan :: proc(v: ivec2) -> int  { return int(v.x) + int(v.y) }

// --- FFI param -> FFI return ---
@(lua=vec3_echo,  table=CodegenTest) cg_test_vec3_echo  :: proc(v: vec3)  -> vec3  { return v }
@(lua=ivec2_echo, table=CodegenTest) cg_test_ivec2_echo :: proc(v: ivec2) -> ivec2 { return v }

// --- Lua table struct roundtrip (primitives only) ---
@(lua=struct_echo, table=CodegenTest) cg_test_struct_echo :: proc(s: Test_Struct) -> Test_Struct { return s }

// --- Struct with FFI fields ---
@(lua)
Cg_Test_Entity :: struct {
    position: vec3,
    tile:     vec2,
    speed:    f32,
    active:   bool,
}

@(lua=entity_echo, table=CodegenTest) cg_test_entity_echo :: proc(e: Cg_Test_Entity) -> Cg_Test_Entity { return e }

// --- Cg_Test_Entity methods (tests colon-call syntax) ---
@(lua=pos_lensq,    method, table=Cg_Test_Entity) cg_test_entity_m_pos_lensq    :: proc(e: Cg_Test_Entity) -> f32 { v := e.position; return v.x*v.x + v.y*v.y + v.z*v.z }
@(lua=active_speed, method, table=Cg_Test_Entity) cg_test_entity_m_active_speed :: proc(e: Cg_Test_Entity) -> f32 { return e.active ? e.speed : 0 }

// --- Struct field reads (non-echo, isolates the read path) ---
@(lua=entity_pos_lensq,      table=CodegenTest) cg_test_entity_pos_lensq :: proc(e: Cg_Test_Entity) -> f32 {
    v := e.position; return v.x*v.x + v.y*v.y + v.z*v.z
}
@(lua=entity_active_speed, table=CodegenTest) cg_test_entity_active_speed :: proc(e: Cg_Test_Entity) -> f32 {
    return e.active ? e.speed : 0
}

// --- mat3 / mat4 FFI ---
@(lua=mat3_trace, table=CodegenTest) cg_test_mat3_trace :: proc(v: mat3) -> f32 { return v[0, 0] + v[1, 1] + v[2, 2] }
@(lua=mat4_trace, table=CodegenTest) cg_test_mat4_trace :: proc(v: mat4) -> f32 { return v[0, 0] + v[1, 1] + v[2, 2] + v[3, 3] }
@(lua=mat3_echo,  table=CodegenTest) cg_test_mat3_echo  :: proc(v: mat3) -> mat3 { return v }
@(lua=mat4_echo,  table=CodegenTest) cg_test_mat4_echo  :: proc(v: mat4) -> mat4 { return v }
