local ffi = require("ffi")
local cmath = require("cmath")

local vec2, vec3, vec4
local 矢量2D, 矢量, 矢量4D

local vec2_funcs = {
    dot = function(a, b) return a.x*b.x + a.y*b.y end,
    cross = function(a, b)
        return a.x*b.y - a.y*b.x
    end,
    length = function(a) return cmath.sqrt(a.x*a.x + a.y*a.y) end,
    normalize = function(a)
        local l = cmath.sqrt(a.x*a.x + a.y*a.y)
        return vec2(a.x/l, a.y/l)
    end,
    lerp = function(a, b, t)
        return vec2(a.x+(b.x-a.x)*t, a.y+(b.y-a.y)*t)
    end,
}

local vec3_funcs = {
    dot = function(a, b) return a.x*b.x + a.y*b.y + a.z*b.z end,
    cross = function(a, b)
        return vec3(a.y*b.z - a.z*b.y,
                    a.z*b.x - a.x*b.z,
                    a.x*b.y - a.y*b.x)
    end,
    length = function(a) return cmath.sqrt(a.x*a.x + a.y*a.y + a.z*a.z) end,
    normalize = function(a)
        local l = cmath.sqrt(a.x*a.x + a.y*a.y + a.z*a.z)
        return vec3(a.x/l, a.y/l, a.z/l)
    end,
    lerp = function(a, b, t)
        return vec3(a.x+(b.x-a.x)*t, a.y+(b.y-a.y)*t, a.z+(b.z-a.z)*t)
    end,
}

local vec4_funcs = {
    dot = function(a, b) return a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w end,
    length = function(a) return cmath.sqrt(a.x*a.x + a.y*a.y + a.z*a.z + a.w*a.w) end,
    normalize = function(a)
        local l = cmath.sqrt(a.x*a.x + a.y*a.y + a.z*a.z + a.w*a.w)
        return vec4(a.x/l, a.y/l, a.z/l, a.w/l)
    end,
    lerp = function(a, b, t)
        return vec4(a.x+(b.x-a.x)*t, a.y+(b.y-a.y)*t, a.z+(b.z-a.z)*t, a.w+(b.w-a.w)*t)
    end,
}

local vec2_funcs_zh = {
    点乘 = vec2_funcs.dot,
    叉乘 = vec2_funcs.cross,
    长度 = vec2_funcs.length,
    标准化 = vec2_funcs.normalize,
    插值 = vec2_funcs.lerp
}

local vec3_funcs_zh = {
    点乘 = vec3_funcs.dot,
    叉乘 = vec3_funcs.cross,
    长度 = vec3_funcs.length,
    标准化 = vec3_funcs.normalize,
    插值 = vec3_funcs.lerp
}

local vec4_funcs_zh = {
    点乘 = vec4_funcs.dot,
    长度 = vec4_funcs.length,
    标准化 = vec4_funcs.normalize,
    插值 = vec4_funcs.lerp
}

for k, v in pairs(vec2_funcs_zh) do vec2_funcs[k] = v end
for k, v in pairs(vec3_funcs_zh) do vec3_funcs[k] = v end
for k, v in pairs(vec4_funcs_zh) do vec4_funcs[k] = v end

local vec2_mt = {
    __add = function(a, b)
        if not (ffi.istype(vec2, a) and ffi.istype(vec2, b)) then
            error("Vec2.__add: both operands must be Vec2")
        end
        return vec2(a.x+b.x, a.y+b.y)
    end,
    __sub = function(a, b)
        if not (ffi.istype(vec2, a) and ffi.istype(vec2, b)) then
            error("Vec2.__sub: both operands must be Vec2")
        end
        return vec2(a.x-b.x, a.y-b.y)
    end,
    __mul = function(a, b)
        if ffi.istype(vec2, a) and ffi.istype(vec2, b) then
            return vec2(a.x*b.x, a.y*b.y)
        elseif type(b) == "number" then
            return vec2(a.x*b, a.y*b)
        elseif type(a) == "number" then
            return vec2(a*b.x, a*b.y)
        else
            error("Vec2.__mul: expected Vec2 or number, got " .. type(a) .. " and " .. type(b))
        end
    end,
    __unm = function(a) return vec2(-a.x, -a.y) end,
    __tostring = function(a) return ("Vec2(%g, %g)"):format(a.x, a.y) end,
    __index = vec2_funcs
}

local vec3_mt = {
    __add = function(a, b)
        if not (ffi.istype(vec3, a) and ffi.istype(vec3, b)) then
            error("Vec3.__add: both operands must be Vec3")
        end
        return vec3(a.x+b.x, a.y+b.y, a.z+b.z)
    end,
    __sub = function(a, b)
        if not (ffi.istype(vec3, a) and ffi.istype(vec3, b)) then
            error("Vec3.__sub: both operands must be Vec3")
        end
        return vec3(a.x-b.x, a.y-b.y, a.z-b.z)
    end,
    __mul = function(a, b)
        if ffi.istype(vec3, a) and ffi.istype(vec3, b) then
            return vec3(a.x*b.x, a.y*b.y, a.z*b.z)
        elseif type(b) == "number" then
            return vec3(a.x*b, a.y*b, a.z*b)
        elseif type(a) == "number" then
            return vec3(a*b.x, a*b.y, a*b.z)
        else
            error("Vec3.__mul: expected Vec3 or number, got " .. type(a) .. " and " .. type(b))
        end
    end,
    __unm = function(a) return vec3(-a.x, -a.y, -a.z) end,
    __tostring = function(a) return ("Vec3(%g, %g, %g)"):format(a.x, a.y, a.z) end,
    __index = vec3_funcs
}

local vec4_mt = {
    __add = function(a, b)
        if not (ffi.istype(vec4, a) and ffi.istype(vec4, b)) then
            error("Vec4.__add: both operands must be Vec4")
        end
        return vec4(a.x+b.x, a.y+b.y, a.z+b.z, a.w+b.w)
    end,
    __sub = function(a, b)
        if not (ffi.istype(vec4, a) and ffi.istype(vec4, b)) then
            error("Vec4.__sub: both operands must be Vec4")
        end
        return vec4(a.x-b.x, a.y-b.y, a.z-b.z, a.w-b.w)
    end,
    __mul = function(a, b)
        if ffi.istype(vec4, a) and ffi.istype(vec4, b) then
            return vec4(a.x*b.x, a.y*b.y, a.z*b.z, a.w*b.w)
        elseif type(b) == "number" then
            return vec4(a.x*b, a.y*b, a.z*b, a.w*b)
        elseif type(a) == "number" then
            return vec4(a*b.x, a*b.y, a*b.z, a*b.w)
        else
            error("Vec4.__mul: expected Vec4 or number, got " .. type(a) .. " and " .. type(b))
        end
    end,
    __unm = function(a) return vec4(-a.x, -a.y, -a.z, -a.w) end,
    __tostring = function(a) return ("Vec4(%g, %g, %g, %g)"):format(a.x, a.y, a.z, a.w) end,
    __index = vec4_funcs
}

vec2 = ffi.metatype("Vec2", vec2_mt)
vec3 = ffi.metatype("Vec3", vec3_mt)
vec4 = ffi.metatype("Vec4", vec4_mt)

return {
    vec2 = vec2,
    vec3 = vec3,
    vec4 = vec4,
}
