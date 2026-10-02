local ffi    = require("ffi")
local cmath  = require("cmath")
local vec    = require("vec")

local vec3 = vec.vec3
local sqrt, sin, cos, acos = cmath.sqrt, cmath.sin, cmath.cos, cmath.acos

local quat

local quat_funcs = {
    length = function(q)
        return sqrt(q.x*q.x + q.y*q.y + q.z*q.z + q.w*q.w)
    end,
    normalize = function(q)
        local il = 1 / sqrt(q.x*q.x + q.y*q.y + q.z*q.z + q.w*q.w)
        return quat(q.x*il, q.y*il, q.z*il, q.w*il)
    end,
    conjugate = function(q)
        return quat(-q.x, -q.y, -q.z, q.w)
    end,
    inverse = function(q)
        local il2 = 1 / (q.x*q.x + q.y*q.y + q.z*q.z + q.w*q.w)
        return quat(-q.x*il2, -q.y*il2, -q.z*il2, q.w*il2)
    end,
    dot = function(a, b)
        return a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w
    end,
    rotate = function(q, v)
        local qx, qy, qz, qw = q.x, q.y, q.z, q.w
        local tx = 2*(qy*v.z - qz*v.y)
        local ty = 2*(qz*v.x - qx*v.z)
        local tz = 2*(qx*v.y - qy*v.x)
        return vec3(v.x + qw*tx + qy*tz - qz*ty,
                    v.y + qw*ty + qz*tx - qx*tz,
                    v.z + qw*tz + qx*ty - qy*tx)
    end,
    slerp = function(a, b, t)
        local d = a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w
        local bx, by, bz, bw = b.x, b.y, b.z, b.w
        if d < 0 then bx,by,bz,bw = -bx,-by,-bz,-bw; d = -d end
        if d > 0.9995 then
            local il = 1/sqrt((a.x+t*(bx-a.x))^2+(a.y+t*(by-a.y))^2+
                               (a.z+t*(bz-a.z))^2+(a.w+t*(bw-a.w))^2)
            return quat((a.x+t*(bx-a.x))*il, (a.y+t*(by-a.y))*il,
                        (a.z+t*(bz-a.z))*il, (a.w+t*(bw-a.w))*il)
        end
        local th0 = acos(d); local th = th0*t
        local s0 = cos(th) - d*sin(th)/sin(th0)
        local s1 = sin(th)/sin(th0)
        return quat(s0*a.x+s1*bx, s0*a.y+s1*by, s0*a.z+s1*bz, s0*a.w+s1*bw)
    end,
}

local quat_funcs_zh = {
    长度    = quat_funcs.length,
    标准化  = quat_funcs.normalize,
    共轭    = quat_funcs.conjugate,
    逆      = quat_funcs.inverse,
    点乘    = quat_funcs.dot,
    旋转    = quat_funcs.rotate,
    球面插值 = quat_funcs.slerp,
}
for k, v in pairs(quat_funcs_zh) do quat_funcs[k] = v end

quat = ffi.metatype("Quat", {
    __mul = function(a, b)
        return quat(a.w*b.x+a.x*b.w+a.y*b.z-a.z*b.y,
                    a.w*b.y-a.x*b.z+a.y*b.w+a.z*b.x,
                    a.w*b.z+a.x*b.y-a.y*b.x+a.z*b.w,
                    a.w*b.w-a.x*b.x-a.y*b.y-a.z*b.z)
    end,
    __unm      = function(q) return quat(-q.x,-q.y,-q.z,-q.w) end,
    __tostring = function(q) return ("Quat(%g,%g,%g,%g)"):format(q.x,q.y,q.z,q.w) end,
    __index    = quat_funcs,
})

-- Module table — callable to construct a Quat directly.
local Quat = setmetatable({
    identity = function()
        return quat(0, 0, 0, 1)
    end,
    axis_angle = function(axis, angle)
        local il   = 1/sqrt(axis.x*axis.x+axis.y*axis.y+axis.z*axis.z)
        local half = angle*0.5; local s = sin(half)
        return quat(axis.x*il*s, axis.y*il*s, axis.z*il*s, cos(half))
    end,
    -- Intrinsic ZYX: pitch=X, yaw=Y, roll=Z (radians)
    euler = function(pitch, yaw, roll)
        local cp,sp = cos(pitch*.5),sin(pitch*.5)
        local cy,sy = cos(yaw  *.5),sin(yaw  *.5)
        local cr,sr = cos(roll *.5),sin(roll *.5)
        return quat(sr*cp*cy-cr*sp*sy, cr*sp*cy+sr*cp*sy,
                    cr*cp*sy-sr*sp*cy, cr*cp*cy+sr*sp*sy)
    end,
}, { __call = function(_, x, y, z, w) return quat(x, y, z, w) end })

Quat.单位   = Quat.identity
Quat.轴角   = Quat.axis_angle
Quat.欧拉角 = Quat.euler

return Quat
