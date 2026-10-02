-- Codegen integration test.
-- Prerequisites: call lua_register_codegen_tests(L) from Odin after lua_init,
-- then require("test_codegen") from your Lua entry point.

---@diagnostic disable-next-line: undefined-field
local CodegenTest = _G.CodegenTest
assert(CodegenTest, "CodegenTest global missing — _lua_register_all_bindings was not called")

local pass, fail = 0, 0

local function check(name, got, expected)
    local ok
    local ng, ne = tonumber(got), tonumber(expected)
    if ng and ne then
        ok = math.abs(ng - ne) < 1e-5
    else
        ok = (got == expected)
    end
    if ok then
        print("PASS  " .. name)
        pass = pass + 1
    else
        print("FAIL  " .. name .. "  got=" .. tostring(got) .. "  expected=" .. tostring(expected))
        fail = fail + 1
    end
end

local T = CodegenTest

-- odin_zh alias: same wrapper reachable under both names
check("zh_primary_name", T.zh_add(3, 4),      7.0)
check("zh_alias_name",   T["相加"](3, 4),     7.0)

-- Primitives
check("add_f32",      T.add_f32(1.5, 2.5),   4.0)
check("add_int",      T.add_int(10, 7),       17)
check("negate_bool",  T.negate_bool(true),    false)
check("negate_bool2", T.negate_bool(false),   true)
check("echo_string",  T.echo_string("hello"), "hello")

-- FFI param -> primitive return
check("vec3_lensq",      T.vec3_lensq(Vec3(3, 4, 0)),  25.0)

-- FFI param -> FFI return (echo round-trip)
local v3 = T.vec3_echo(Vec3(1, 2, 3))
check("vec3_echo.x", v3.x, 1)
check("vec3_echo.y", v3.y, 2)
check("vec3_echo.z", v3.z, 3)

-- Lua table struct roundtrip
local s_out = T.struct_echo({ a = 1.5, b = 2, c = 3.0, d = -4 })
check("struct_echo.a", s_out.a,  1.5)
check("struct_echo.b", s_out.b,  2)
check("struct_echo.c", s_out.c,  3.0)
check("struct_echo.d", s_out.d, -4)

-- Struct with FFI fields (Cg_Test_Entity)
local e_out = T.entity_echo({
    position = Vec3(1, 2, 3),
    tile     = Vec2(4, 5),
    speed    = 1.5,
    active   = true,
})
check("entity_echo.position.x", e_out.position.x, 1)
check("entity_echo.position.y", e_out.position.y, 2)
check("entity_echo.position.z", e_out.position.z, 3)
check("entity_echo.tile.x",     e_out.tile.x,     4)
check("entity_echo.tile.y",     e_out.tile.y,     5)
check("entity_echo.speed",      e_out.speed,      1.5)
check("entity_echo.active",     e_out.active,     true)

-- Method call syntax: entity_echo returns a table via _lua_push_table_Cg_Test_Entity,
-- which attaches the metatable, enabling e:method() colon-call syntax.
local em = T.entity_echo({ position = Vec3(3, 4, 0), tile = Vec2(0, 0), speed = 2.0, active = true })
check("method_pos_lensq",        em:pos_lensq(),    25.0)
check("method_active_speed_on",  em:active_speed(), 2.0)
em.active = false
check("method_active_speed_off", em:active_speed(), 0)

-- Lua-side mutation tests: Lua writes/mutates, Odin reads a computed scalar.
-- These isolate the read path independently of the push path.

-- FFI mutation: modify a vec3 field after construction, check Odin reads the new value.
local vm = Vec3(3, 0, 0)
vm.y = 4
check("vec3_mutation_lensq", T.vec3_lensq(vm), 25.0)  -- 3²+4² = 25

-- FFI mutation: modify a mat4 element directly, check trace reflects it.
local m4z = Mat4()
m4z.m[5] = 3.14   -- col 1, row 1 (only non-zero diagonal)
check("mat4_mutation_trace", T.mat4_trace(m4z), 3.14)

-- Struct with FFI sub-fields: non-echo, computes scalar from entity.position.
local e1 = { position = Vec3(3, 4, 0), tile = Vec2(0, 0), speed = 1.5, active = true }
check("entity_pos_lensq",        T.entity_pos_lensq(e1),      25.0)
check("entity_active_speed_on",  T.entity_active_speed(e1),   1.5)

-- Mutate the FFI position cdata in-place; Odin must see the changed values.
e1.position.x = 0
check("entity_pos_lensq_mutated", T.entity_pos_lensq(e1), 16.0)  -- 0²+4²+0² = 16

-- Mutate the Lua-table bool field; Odin must see the changed value.
e1.active = false
check("entity_active_speed_off", T.entity_active_speed(e1), 0)

-- mat3 / mat4 FFI
check("mat3_trace_identity", T.mat3_trace(Mat3.identity()), 3.0)
check("mat4_trace_identity", T.mat4_trace(Mat4.identity()), 4.0)

-- mat4 echo: translation matrix, verify translation column and diagonal survive
local m4t = Mat4.translation(7, 8, 9)
local m4r = T.mat4_echo(m4t)
check("mat4_echo.m[0]",  m4r.m[0],  1)   -- diagonal
check("mat4_echo.m[12]", m4r.m[12], 7)   -- translation x
check("mat4_echo.m[13]", m4r.m[13], 8)   -- translation y
check("mat4_echo.m[14]", m4r.m[14], 9)   -- translation z
check("mat4_echo.m[15]", m4r.m[15], 1)

-- mat3 echo: set distinct diagonal values, verify they survive
local m3 = Mat3()
m3.m[0] = 2; m3.m[4] = 5; m3.m[8] = 9
local m3r = T.mat3_echo(m3)
check("mat3_echo.m[0]", m3r.m[0], 2)
check("mat3_echo.m[4]", m3r.m[4], 5)
check("mat3_echo.m[8]", m3r.m[8], 9)

print(string.format("\n%d passed, %d failed", pass, fail))
