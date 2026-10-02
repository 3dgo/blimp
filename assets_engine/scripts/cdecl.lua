local ffi = require("ffi")

ffi.cdef[[
    /* math */
    float sqrtf(float x);
    float fabsf(float x);
    float sinf(float x);
    float cosf(float x);
    float tanf(float x);
    float asinf(float x);
    float acosf(float x);
    float atanf(float x);
    float atan2f(float y, float x);
    float powf(float x, float y);
    float expf(float x);
    float logf(float x);
    float log2f(float x);
    float log10f(float x);
    float floorf(float x);
    float ceilf(float x);
    float roundf(float x);
    float fmodf(float x, float y);

    /* vectors and matrices (column-major) */
    typedef union {
        struct { float x, y; };
        float v[2];
    } Vec2;

    typedef union {
        struct { float x, y, z; };
        float v[3];
    } Vec3;

    typedef union {
        struct { float x, y, z, w; };
        float v[4];
    } Vec4;

    typedef struct { float x, y, z, w; } Quat;
    
    typedef struct { float m[9];        } Mat3;
    typedef struct { float m[16];       } Mat4;
]]

return ffi.C