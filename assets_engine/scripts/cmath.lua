local C = require("cdecl")

local cmath = {}

-- Constants
cmath.pi  = 3.14159265358979323846
cmath.tau = 6.28318530717958647692
cmath.e   = 2.71828182845904523536
cmath.inf = math.huge

-- C functions
cmath.sqrt  = C.sqrtf
cmath.sin   = C.sinf
cmath.cos   = C.cosf
cmath.tan   = C.tanf
cmath.asin  = C.asinf
cmath.acos  = C.acosf
cmath.atan  = C.atanf
cmath.atan2 = C.atan2f
cmath.pow   = C.powf
cmath.exp   = C.expf
cmath.log   = C.logf
cmath.log2  = C.log2f
cmath.log10 = C.log10f
cmath.floor = C.floorf
cmath.ceil  = C.ceilf
cmath.round = C.roundf
cmath.fmod  = C.fmodf

-- Pure Lua
cmath.abs      = math.abs
cmath.sign     = function(x) return x > 0 and 1 or (x < 0 and -1 or 0) end
cmath.min      = math.min
cmath.max      = math.max
cmath.clamp    = function(x, lo, hi) return x < lo and lo or (x > hi and hi or x) end
cmath.saturate = function(x) return x < 0 and 0 or (x > 1 and 1 or x) end
cmath.lerp     = function(a, b, t) return a + (b - a) * t end
cmath.step     = function(edge, x) return x < edge and 0 or 1 end
cmath.smoothstep = function(lo, hi, x)
    if lo == hi then return x >= hi and 1 or 0 end
    local t = cmath.clamp((x - lo) / (hi - lo), 0, 1)
    return t * t * (3 - 2 * t)
end
cmath.degrees  = math.deg
cmath.radians  = math.rad

-- Chinese aliases — constants
cmath.圆周率    = cmath.pi
cmath.自然常数  = cmath.e
cmath.无穷大    = cmath.inf

-- Chinese aliases — functions
cmath.开方        = cmath.sqrt
cmath.绝对值      = cmath.abs
cmath.正弦        = cmath.sin
cmath.余弦        = cmath.cos
cmath.正切        = cmath.tan
cmath.反正弦      = cmath.asin
cmath.反余弦      = cmath.acos
cmath.反正切      = cmath.atan
cmath.反正切2     = cmath.atan2
cmath.幂          = cmath.pow
cmath.指数        = cmath.exp
cmath.对数        = cmath.log
cmath.二进制对数  = cmath.log2
cmath.常用对数    = cmath.log10
cmath.向下取整    = cmath.floor
cmath.向上取整    = cmath.ceil
cmath.四舍五入    = cmath.round
cmath.浮点取余    = cmath.fmod
cmath.符号        = cmath.sign
cmath.最小值      = cmath.min
cmath.最大值      = cmath.max
cmath.夹紧        = cmath.clamp
cmath.截断        = cmath.saturate
cmath.插值        = cmath.lerp
cmath.阶跃        = cmath.step
cmath.平滑阶跃    = cmath.smoothstep
cmath.弧度转角度  = cmath.degrees
cmath.角度转弧度  = cmath.radians

return cmath
