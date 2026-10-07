---@meta
-- LuaLS type definitions for Chinese/English global aliases.
-- Each Chinese global is typed with a Chinese-only class, and each English
-- global with an English-only class, so autocomplete never mixes the two.
-- Chinese types and globals live in lua_chinese_defs.lua.

-- ── cmath ─────────────────────────────────────────────────────────────

---@class CmathEN
---@field pi         number
---@field tau        number
---@field e          number
---@field inf        number
---@field sqrt       fun(x: number): number
---@field sin        fun(x: number): number
---@field cos        fun(x: number): number
---@field tan        fun(x: number): number
---@field asin       fun(x: number): number
---@field acos       fun(x: number): number
---@field atan       fun(x: number): number
---@field atan2      fun(y: number, x: number): number
---@field pow        fun(x: number, y: number): number
---@field exp        fun(x: number): number
---@field log        fun(x: number): number
---@field log2       fun(x: number): number
---@field log10      fun(x: number): number
---@field floor      fun(x: number): number
---@field ceil       fun(x: number): number
---@field round      fun(x: number): number
---@field fmod       fun(x: number, y: number): number
---@field abs        fun(x: number): number
---@field sign       fun(x: number): number
---@field min        fun(a: number, b: number): number
---@field max        fun(a: number, b: number): number
---@field clamp      fun(x: number, lo: number, hi: number): number
---@field saturate   fun(x: number): number
---@field lerp       fun(a: number, b: number, t: number): number
---@field step       fun(edge: number, x: number): number
---@field smoothstep fun(lo: number, hi: number, x: number): number
---@field degrees    fun(r: number): number
---@field radians    fun(d: number): number

---@type CmathEN
CMath = nil

-- ── Vec2 ──────────────────────────────────────────────────────────────

---@class Vec2
---@field x number
---@field y number
---@field dot       fun(self: Vec2, b: Vec2): number
---@field cross     fun(self: Vec2, b: Vec2): number
---@field length    fun(self: Vec2): number
---@field normalize fun(self: Vec2): Vec2
---@field lerp      fun(self: Vec2, b: Vec2, t: number): Vec2

---@type fun(x: number, y: number): Vec2
Vec2 = nil

-- ── Vec3 ──────────────────────────────────────────────────────────────

---@class Vec3
---@field x number
---@field y number
---@field z number
---@field dot       fun(self: Vec3, b: Vec3): number
---@field cross     fun(self: Vec3, b: Vec3): Vec3
---@field length    fun(self: Vec3): number
---@field normalize fun(self: Vec3): Vec3
---@field lerp      fun(self: Vec3, b: Vec3, t: number): Vec3

---@type fun(x: number, y: number, z: number): Vec3
Vec3 = nil

-- ── Vec4 ──────────────────────────────────────────────────────────────

---@class Vec4
---@field x number
---@field y number
---@field z number
---@field w number
---@field dot       fun(self: Vec4, b: Vec4): number
---@field length    fun(self: Vec4): number
---@field normalize fun(self: Vec4): Vec4
---@field lerp      fun(self: Vec4, b: Vec4, t: number): Vec4

---@type fun(x: number, y: number, z: number, w: number): Vec4
Vec4 = nil

-- ── Quat ──────────────────────────────────────────────────────────────

---@class Quat
---@field x number
---@field y number
---@field z number
---@field w number
---@field length    fun(self: Quat): number
---@field normalize fun(self: Quat): Quat
---@field conjugate fun(self: Quat): Quat
---@field inverse   fun(self: Quat): Quat
---@field dot       fun(self: Quat, b: Quat): number
---@field rotate    fun(self: Quat, v: Vec3): Vec3
---@field slerp     fun(self: Quat, b: Quat, t: number): Quat

---@class QuatClass : Quat
---@overload fun(x: number, y: number, z: number, w: number): Quat
---@field identity   fun(): Quat
---@field axis_angle fun(axis: Vec3, angle: number): Quat
---@field euler      fun(pitch: number, yaw: number, roll: number): Quat

---@type QuatClass
Quat = nil

-- ── Mat3 ──────────────────────────────────────────────────────────────

---@class Mat3
---@field m number[]
---@field transpose     fun(self: Mat3): Mat3
---@field inverse       fun(self: Mat3): Mat3
---@field transform     fun(self: Mat3, v: Vec3): Vec3
---@field normal_matrix fun(self: Mat3): Mat3

---@class Mat3Class : Mat3
---@overload fun(): Mat3
---@field identity  fun(): Mat3
---@field from_quat fun(q: Quat): Mat3

---@type Mat3Class
Mat3 = nil

-- ── Mat4 ──────────────────────────────────────────────────────────────

---@class Mat4
---@field m number[]
---@field transpose     fun(self: Mat4): Mat4
---@field inverse       fun(self: Mat4): Mat4
---@field transform_point fun(self: Mat4, v: Vec3): Vec3
---@field transform_dir   fun(self: Mat4, v: Vec3): Vec3
---@field transform_vec4  fun(self: Mat4, v: Vec4): Vec4
---@field to_mat3         fun(self: Mat4): Mat3

---@class Mat4Class : Mat4
---@overload fun(): Mat4
---@field identity   fun(): Mat4
---@field translation fun(x: number, y: number, z: number): Mat4
---@field scale       fun(x: number, y: number, z: number): Mat4
---@field rotation_x  fun(angle: number): Mat4
---@field rotation_y  fun(angle: number): Mat4
---@field rotation_z  fun(angle: number): Mat4
---@field from_quat   fun(q: Quat): Mat4
---@field trs         fun(t: Vec3, r: Quat, s: Vec3): Mat4
---@field look_at     fun(eye: Vec3, center: Vec3, up: Vec3): Mat4
---@field perspective  fun(fov: number, aspect: number, near: number, far: number): Mat4
---@field ortho        fun(l: number, r: number, b: number, t: number, near: number, far: number): Mat4

---@type Mat4Class
Mat4 = nil

-- ── Blimp ─────────────────────────────────────────────────────────────

---@class Blimp
Blimp = nil

-- ── Hooks ─────────────────────────────────────────────────────────────
-- Scripts define these and the engine calls them; declared here only for completion and hover.

---Called once after main.lua loads (and after it hot reloads). main.lua defines it.
function Blimp.start() end

---Called every frame, while editing and playing. Not in any world: World, Entity and Anim don't work here; Input does.
---@param dt number this frame's seconds
function Blimp.update(dt) end

---Called once before the engine shuts down. main.lua defines it.
function Blimp.finish() end

---Called on every Play (and after a script reload). Look up the level's fixed entities here with World.get.
function World.start() end

---Called each tick the level advances: not while paused, once per F10 step. Animate from World.time().
---@param dt number this tick's seconds
function World.update(dt) end

---Called after a character's clip passes an event (a frame marked in its .clips file, like a footstep). Only a
---clip with over half the current pose fires, so a blend doesn't fire it twice; seeking doesn't fire.
---@param entity Entity_Handle the entity playing the clip
---@param name string the event's name, like "footstep"
function World.anim_event(entity, name) end
