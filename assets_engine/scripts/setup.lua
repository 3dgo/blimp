package.path = "assets_engine/scripts/?.lua;" .. "assets/scripts/?.lua;" .. package.path

require("cdecl")

_G.CMath = require("cmath")
_G.数学   = _G.CMath  --[[@as CmathZH]]

local vec = require("vec")
_G.Vec2, _G.Vec3, _G.Vec4 = vec.vec2, vec.vec3, vec.vec4
_G.矢量2  = _G.Vec2   --[[@as fun(x: number, y: number): Vec2ZH]]
_G.矢量3  = _G.Vec3   --[[@as fun(x: number, y: number, z: number): Vec3ZH]]
_G.矢量4  = _G.Vec4   --[[@as fun(x: number, y: number, z: number, w: number): Vec4ZH]]

_G.Quat = require("quat")
_G.四元数 = _G.Quat   --[[@as QuatZHClass]]

local mm = require("mat")
_G.Mat3, _G.Mat4 = mm.mat3, mm.mat4
_G._push_mat3 = mm.mat3.push_mat3
_G._push_mat4 = mm.mat4.push_mat4
_G.矩阵3  = _G.Mat3   --[[@as Mat3ZHClass]]
_G.矩阵4  = _G.Mat4   --[[@as Mat4ZHClass]]

-- Binding tables for @(lua, table=Blimp/Entity/World/Input) procs. Created empty here so the Chinese
-- aliases reference the same table object; _lua_register_all_bindings (run after this file)
-- fills these existing tables rather than replacing them.
_G.Blimp  = {}   -- also where main.lua defines the engine hooks (lua.odin)
_G.引擎   = _G.Blimp   --[[@as 引擎]]
_G.Entity = {}
_G.实体   = _G.Entity   --[[@as 实体]]
_G.World  = {}
_G.世界   = _G.World   --[[@as 世界]]
_G.Input  = {}   -- input.odin: keys, mouse, gamepad (live in game mode)
_G.输入   = _G.Input   --[[@as 输入]]
_G.Anim   = {}   -- world_anim.odin: sample, blend and output poses each update (claude/animation.md)
_G.动画   = _G.Anim   --[[@as 动画]]

require("stdlib_aliases")
