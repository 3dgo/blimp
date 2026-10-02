local ffi   = require("ffi")
local cmath = require("cmath")
local vec   = require("vec")

local vec3, vec4 = vec.vec3, vec.vec4
local sqrt, sin, cos, tan = cmath.sqrt, cmath.sin, cmath.cos, cmath.tan

-- Column-major: element (row r, col c) lives at m[c*R+r], where R=4 (mat4) or 3 (mat3).

local mat3, mat4 = {}, {}
local mat3_ctype, mat4_ctype

-- ============================================================
--  mat4 methods
-- ============================================================

local mat4_funcs = {
    transpose = function(a)
        local r = mat4_ctype()
        for c=0,3 do for row=0,3 do r.m[row*4+c]=a.m[c*4+row] end end
        return r
    end,
    inverse = function(a)
        local m=a.m; local o=mat4_ctype(); local i=o.m
        i[0] = m[5]*m[10]*m[15]-m[5]*m[11]*m[14]-m[9]*m[6]*m[15]+m[9]*m[7]*m[14]+m[13]*m[6]*m[11]-m[13]*m[7]*m[10]
        i[4] =-m[4]*m[10]*m[15]+m[4]*m[11]*m[14]+m[8]*m[6]*m[15]-m[8]*m[7]*m[14]-m[12]*m[6]*m[11]+m[12]*m[7]*m[10]
        i[8] = m[4]*m[9] *m[15]-m[4]*m[11]*m[13]-m[8]*m[5]*m[15]+m[8]*m[7]*m[13]+m[12]*m[5]*m[11]-m[12]*m[7]*m[9]
        i[12]=-m[4]*m[9] *m[14]+m[4]*m[10]*m[13]+m[8]*m[5]*m[14]-m[8]*m[6]*m[13]-m[12]*m[5]*m[10]+m[12]*m[6]*m[9]
        i[1] =-m[1]*m[10]*m[15]+m[1]*m[11]*m[14]+m[9]*m[2]*m[15]-m[9]*m[3]*m[14]-m[13]*m[2]*m[11]+m[13]*m[3]*m[10]
        i[5] = m[0]*m[10]*m[15]-m[0]*m[11]*m[14]-m[8]*m[2]*m[15]+m[8]*m[3]*m[14]+m[12]*m[2]*m[11]-m[12]*m[3]*m[10]
        i[9] =-m[0]*m[9] *m[15]+m[0]*m[11]*m[13]+m[8]*m[1]*m[15]-m[8]*m[3]*m[13]-m[12]*m[1]*m[11]+m[12]*m[3]*m[9]
        i[13]= m[0]*m[9] *m[14]-m[0]*m[10]*m[13]-m[8]*m[1]*m[14]+m[8]*m[2]*m[13]+m[12]*m[1]*m[10]-m[12]*m[2]*m[9]
        i[2] = m[1]*m[6] *m[15]-m[1]*m[7] *m[14]-m[5]*m[2]*m[15]+m[5]*m[3]*m[14]+m[13]*m[2]*m[7] -m[13]*m[3]*m[6]
        i[6] =-m[0]*m[6] *m[15]+m[0]*m[7] *m[14]+m[4]*m[2]*m[15]-m[4]*m[3]*m[14]-m[12]*m[2]*m[7] +m[12]*m[3]*m[6]
        i[10]= m[0]*m[5] *m[15]-m[0]*m[7] *m[13]-m[4]*m[1]*m[15]+m[4]*m[3]*m[13]+m[12]*m[1]*m[7] -m[12]*m[3]*m[5]
        i[14]=-m[0]*m[5] *m[14]+m[0]*m[6] *m[13]+m[4]*m[1]*m[14]-m[4]*m[2]*m[13]-m[12]*m[1]*m[6] +m[12]*m[2]*m[5]
        i[3] =-m[1]*m[6] *m[11]+m[1]*m[7] *m[10]+m[5]*m[2]*m[11]-m[5]*m[3]*m[10]-m[9] *m[2]*m[7] +m[9] *m[3]*m[6]
        i[7] = m[0]*m[6] *m[11]-m[0]*m[7] *m[10]-m[4]*m[2]*m[11]+m[4]*m[3]*m[10]+m[8] *m[2]*m[7] -m[8] *m[3]*m[6]
        i[11]=-m[0]*m[5] *m[11]+m[0]*m[7] *m[9] +m[4]*m[1]*m[11]-m[4]*m[3]*m[9] -m[8] *m[1]*m[7] +m[8] *m[3]*m[5]
        i[15]= m[0]*m[5] *m[10]-m[0]*m[6] *m[9] -m[4]*m[1]*m[10]+m[4]*m[2]*m[9] +m[8] *m[1]*m[6] -m[8] *m[2]*m[5]
        local det=m[0]*i[0]+m[1]*i[4]+m[2]*i[8]+m[3]*i[12]
        if det==0 then return nil end
        local id=1/det; for j=0,15 do i[j]=i[j]*id end
        return o
    end,
    transform_point = function(a, v)
        local m=a.m
        local iw=1/(m[3]*v.x+m[7]*v.y+m[11]*v.z+m[15])
        return vec3((m[0]*v.x+m[4]*v.y+m[8] *v.z+m[12])*iw,
                    (m[1]*v.x+m[5]*v.y+m[9] *v.z+m[13])*iw,
                    (m[2]*v.x+m[6]*v.y+m[10]*v.z+m[14])*iw)
    end,
    transform_dir = function(a, v)
        local m=a.m
        return vec3(m[0]*v.x+m[4]*v.y+m[8] *v.z,
                    m[1]*v.x+m[5]*v.y+m[9] *v.z,
                    m[2]*v.x+m[6]*v.y+m[10]*v.z)
    end,
    transform_vec4 = function(a, v)
        local m=a.m
        return vec4(m[0]*v.x+m[4]*v.y+m[8] *v.z+m[12]*v.w,
                    m[1]*v.x+m[5]*v.y+m[9] *v.z+m[13]*v.w,
                    m[2]*v.x+m[6]*v.y+m[10]*v.z+m[14]*v.w,
                    m[3]*v.x+m[7]*v.y+m[11]*v.z+m[15]*v.w)
    end,
    to_mat3 = function(a)
        local r=mat3_ctype()
        r.m[0]=a.m[0];r.m[1]=a.m[1];r.m[2]=a.m[2]
        r.m[3]=a.m[4];r.m[4]=a.m[5];r.m[5]=a.m[6]
        r.m[6]=a.m[8];r.m[7]=a.m[9];r.m[8]=a.m[10]
        return r
    end,
}

local mat4_funcs_zh = {
    转置     = mat4_funcs.transpose,
    逆矩阵   = mat4_funcs.inverse,
    变换点   = mat4_funcs.transform_point,
    变换方向 = mat4_funcs.transform_dir,
    变换向量 = mat4_funcs.transform_vec4,
    转矩阵3  = mat4_funcs.to_mat3,
}
for k,v in pairs(mat4_funcs_zh) do mat4_funcs[k]=v end

-- Push helpers called from Odin: receive elements in column-major order.
function mat3.push_mat3(m0,m1,m2,m3,m4,m5,m6,m7,m8)
    local r=mat3_ctype()
    r.m[0]=m0;r.m[1]=m1;r.m[2]=m2
    r.m[3]=m3;r.m[4]=m4;r.m[5]=m5
    r.m[6]=m6;r.m[7]=m7;r.m[8]=m8
    return r
end

function mat4.push_mat4(m0,m1,m2,m3,m4,m5,m6,m7,m8,m9,m10,m11,m12,m13,m14,m15)
    local r=mat4_ctype()
    r.m[0]=m0;r.m[1]=m1;r.m[2]=m2;r.m[3]=m3
    r.m[4]=m4;r.m[5]=m5;r.m[6]=m6;r.m[7]=m7
    r.m[8]=m8;r.m[9]=m9;r.m[10]=m10;r.m[11]=m11
    r.m[12]=m12;r.m[13]=m13;r.m[14]=m14;r.m[15]=m15
    return r
end

-- ============================================================
--  mat3 methods
-- ============================================================

local mat3_funcs = {
    transpose = function(a)
        local r=mat3_ctype()
        for c=0,2 do for row=0,2 do r.m[row*3+c]=a.m[c*3+row] end end
        return r
    end,
    inverse = function(a)
        local m=a.m
        local det=m[0]*(m[4]*m[8]-m[7]*m[5])-m[3]*(m[1]*m[8]-m[7]*m[2])+m[6]*(m[1]*m[5]-m[4]*m[2])
        if det==0 then return nil end
        local id=1/det; local r=mat3_ctype()
        r.m[0]= (m[4]*m[8]-m[5]*m[7])*id; r.m[1]=-(m[1]*m[8]-m[2]*m[7])*id; r.m[2]= (m[1]*m[5]-m[2]*m[4])*id
        r.m[3]=-(m[3]*m[8]-m[5]*m[6])*id; r.m[4]= (m[0]*m[8]-m[2]*m[6])*id; r.m[5]=-(m[0]*m[5]-m[2]*m[3])*id
        r.m[6]= (m[3]*m[7]-m[4]*m[6])*id; r.m[7]=-(m[0]*m[7]-m[1]*m[6])*id; r.m[8]= (m[0]*m[4]-m[1]*m[3])*id
        return r
    end,
    transform = function(a, v)
        local m=a.m
        return vec3(m[0]*v.x+m[3]*v.y+m[6]*v.z,
                    m[1]*v.x+m[4]*v.y+m[7]*v.z,
                    m[2]*v.x+m[5]*v.y+m[8]*v.z)
    end,
}

mat3_funcs.normal_matrix = function(a)
    return mat3_funcs.transpose(mat3_funcs.inverse(a))
end

local mat3_funcs_zh = {
    转置     = mat3_funcs.transpose,
    逆矩阵   = mat3_funcs.inverse,
    变换     = mat3_funcs.transform,
    法线矩阵 = mat3_funcs.normal_matrix,
}
for k,v in pairs(mat3_funcs_zh) do mat3_funcs[k]=v end

-- ============================================================
--  Metatypes
-- ============================================================

mat3_ctype = ffi.metatype("Mat3", {
    __mul = function(a, b)
        local r=mat3_ctype()
        for c=0,2 do for row=0,2 do
            local s=0; for k=0,2 do s=s+a.m[k*3+row]*b.m[c*3+k] end
            r.m[c*3+row]=s
        end end
        return r
    end,
    __tostring = function(a)
        local m=a.m
        return ("mat3\n|%6.3f %6.3f %6.3f|\n|%6.3f %6.3f %6.3f|\n|%6.3f %6.3f %6.3f|")
            :format(m[0],m[3],m[6],m[1],m[4],m[7],m[2],m[5],m[8])
    end,
    __index = mat3_funcs,
})

mat4_ctype = ffi.metatype("Mat4", {
    __mul = function(a, b)
        local r=mat4_ctype()
        for c=0,3 do for row=0,3 do
            local s=0; for k=0,3 do s=s+a.m[k*4+row]*b.m[c*4+k] end
            r.m[c*4+row]=s
        end end
        return r
    end,
    __tostring = function(a)
        local m=a.m
        return ("mat4\n|%6.3f %6.3f %6.3f %6.3f|\n|%6.3f %6.3f %6.3f %6.3f|\n|%6.3f %6.3f %6.3f %6.3f|\n|%6.3f %6.3f %6.3f %6.3f|")
            :format(m[0],m[4],m[8],m[12],m[1],m[5],m[9],m[13],m[2],m[6],m[10],m[14],m[3],m[7],m[11],m[15])
    end,
    __index = mat4_funcs,
})

-- ============================================================
--  Module tables — callable to construct a raw value directly.
-- ============================================================

mat3 = setmetatable({
    identity = function()
        local r=mat3_ctype(); r.m[0]=1;r.m[4]=1;r.m[8]=1; return r
    end,
    from_quat = function(q)
        local x,y,z,w=q.x,q.y,q.z,q.w; local r=mat3_ctype()
        r.m[0]=1-2*(y*y+z*z); r.m[1]=2*(x*y+w*z); r.m[2]=2*(x*z-w*y)
        r.m[3]=2*(x*y-w*z);   r.m[4]=1-2*(x*x+z*z); r.m[5]=2*(y*z+w*x)
        r.m[6]=2*(x*z+w*y);   r.m[7]=2*(y*z-w*x); r.m[8]=1-2*(x*x+y*y)
        return r
    end,
}, { __call = function(_, m0,m1,m2,m3,m4,m5,m6,m7,m8)
    local r = mat3_ctype()
    if m0 then
        r.m[0]=m0; r.m[1]=m1; r.m[2]=m2
        r.m[3]=m3; r.m[4]=m4; r.m[5]=m5
        r.m[6]=m6; r.m[7]=m7; r.m[8]=m8
    end
    return r
end })

mat3.单位   = mat3.identity
mat3.从四元数 = mat3.from_quat

mat4 = setmetatable({
    identity = function()
        local r=mat4_ctype(); r.m[0]=1;r.m[5]=1;r.m[10]=1;r.m[15]=1; return r
    end,
    translation = function(x, y, z)
        local r=mat4_ctype(); r.m[0]=1;r.m[5]=1;r.m[10]=1;r.m[15]=1
        r.m[12]=x;r.m[13]=y;r.m[14]=z; return r
    end,
    scale = function(x, y, z)
        local r=mat4_ctype(); r.m[0]=x;r.m[5]=y;r.m[10]=z;r.m[15]=1; return r
    end,
    rotation_x = function(a)
        local c,s=cos(a),sin(a); local r=mat4_ctype()
        r.m[0]=1;r.m[5]=c;r.m[9]=-s;r.m[6]=s;r.m[10]=c;r.m[15]=1; return r
    end,
    rotation_y = function(a)
        local c,s=cos(a),sin(a); local r=mat4_ctype()
        r.m[0]=c;r.m[8]=s;r.m[2]=-s;r.m[10]=c;r.m[5]=1;r.m[15]=1; return r
    end,
    rotation_z = function(a)
        local c,s=cos(a),sin(a); local r=mat4_ctype()
        r.m[0]=c;r.m[4]=-s;r.m[1]=s;r.m[5]=c;r.m[10]=1;r.m[15]=1; return r
    end,
    from_quat = function(q)
        local x,y,z,w=q.x,q.y,q.z,q.w; local r=mat4_ctype()
        r.m[0] =1-2*(y*y+z*z); r.m[1] =2*(x*y+w*z); r.m[2] =2*(x*z-w*y)
        r.m[4] =2*(x*y-w*z);   r.m[5] =1-2*(x*x+z*z); r.m[6] =2*(y*z+w*x)
        r.m[8] =2*(x*z+w*y);   r.m[9] =2*(y*z-w*x); r.m[10]=1-2*(x*x+y*y)
        r.m[15]=1; return r
    end,
    trs = function(pos, rot, scl)
        local x,y,z,w=rot.x,rot.y,rot.z,rot.w
        local sx,sy,sz=scl.x,scl.y,scl.z; local r=mat4_ctype()
        r.m[0] =(1-2*(y*y+z*z))*sx; r.m[1] =2*(x*y+w*z)*sx; r.m[2] =2*(x*z-w*y)*sx
        r.m[4] =2*(x*y-w*z)*sy;     r.m[5] =(1-2*(x*x+z*z))*sy; r.m[6] =2*(y*z+w*x)*sy
        r.m[8] =2*(x*z+w*y)*sz;     r.m[9] =2*(y*z-w*x)*sz; r.m[10]=(1-2*(x*x+y*y))*sz
        r.m[12]=pos.x; r.m[13]=pos.y; r.m[14]=pos.z; r.m[15]=1
        return r
    end,
    look_at = function(eye, center, up)
        local fx=center.x-eye.x; local fy=center.y-eye.y; local fz=center.z-eye.z
        local il=1/sqrt(fx*fx+fy*fy+fz*fz); fx=fx*il;fy=fy*il;fz=fz*il
        local rx=fy*up.z-fz*up.y; local ry=fz*up.x-fx*up.z; local rz=fx*up.y-fy*up.x
        il=1/sqrt(rx*rx+ry*ry+rz*rz); rx=rx*il;ry=ry*il;rz=rz*il
        local ux=ry*fz-rz*fy; local uy=rz*fx-rx*fz; local uz=rx*fy-ry*fx
        local r=mat4_ctype()
        r.m[0]=rx;r.m[1]=ux;r.m[2]=-fx
        r.m[4]=ry;r.m[5]=uy;r.m[6]=-fy
        r.m[8]=rz;r.m[9]=uz;r.m[10]=-fz
        r.m[12]=-(rx*eye.x+ry*eye.y+rz*eye.z)
        r.m[13]=-(ux*eye.x+uy*eye.y+uz*eye.z)
        r.m[14]= (fx*eye.x+fy*eye.y+fz*eye.z)
        r.m[15]=1; return r
    end,
    -- Right-handed, depth [0,1], Y-flipped for Vulkan.
    perspective = function(fov_y, aspect, near, far)
        local itan=1/tan(fov_y*0.5); local r=mat4_ctype()
        r.m[0]=itan/aspect; r.m[5]=-itan
        r.m[10]=far/(near-far); r.m[11]=-1
        r.m[14]=near*far/(near-far); return r
    end,
    ortho = function(left, right, bottom, top, near, far)
        local r=mat4_ctype()
        r.m[0]=2/(right-left);  r.m[5]=-2/(top-bottom)
        r.m[10]=1/(near-far);   r.m[12]=-(right+left)/(right-left)
        r.m[13]=(top+bottom)/(top-bottom); r.m[14]=near/(near-far); r.m[15]=1
        return r
    end,
}, { __call = function(_, m0,m1,m2,m3,m4,m5,m6,m7,m8,m9,m10,m11,m12,m13,m14,m15)
    local r = mat4_ctype()
    if m0 then
        r.m[0]=m0;  r.m[1]=m1;  r.m[2]=m2;  r.m[3]=m3
        r.m[4]=m4;  r.m[5]=m5;  r.m[6]=m6;  r.m[7]=m7
        r.m[8]=m8;  r.m[9]=m9;  r.m[10]=m10; r.m[11]=m11
        r.m[12]=m12; r.m[13]=m13; r.m[14]=m14; r.m[15]=m15
    end
    return r
end })

mat4.单位   = mat4.identity
mat4.平移   = mat4.translation
mat4.缩放   = mat4.scale
mat4.绕X旋转 = mat4.rotation_x
mat4.绕Y旋转 = mat4.rotation_y
mat4.绕Z旋转 = mat4.rotation_z
mat4.从四元数 = mat4.from_quat
mat4.变换矩阵 = mat4.trs
mat4.观察   = mat4.look_at
mat4.透视   = mat4.perspective
mat4.正交   = mat4.ortho

return { mat3 = mat3, mat4 = mat4 }
