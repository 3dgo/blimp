# Gameplay systems

### State

Priority-ordered condition list, first match wins. No transition graphs — the web happens
because graphs force you to enumerate transitions that are really conditions.

```odin
states := []State_Rule{
    {.Dead,   proc(c) -> bool { return c.health <= 0 }},
    {.Hit,    proc(c) -> bool { return c.hit_timer > 0 }},
    {.Attack, proc(c) -> bool { return c.attack_active }},
    {.Fall,   proc(c) -> bool { return !c.grounded }},
    {.Move,   proc(c) -> bool { return c.input_len > 0.1 }},
    {.Idle,   proc(c) -> bool { return true }},
}
```

Adding a state is one line and it's reachable from everywhere below it. Combo chains check
current state inside the rule. Interruptibility as per-state cancel windows.

Same structure for AI. Effort goes into perception and steering, not decision structure.

### Entities

- Wrap the handle map, don't hijack it. `world_add` / `world_remove` update anything parallel.
- If filtering gets expensive: a `u32` flags array per entity (scan 4 bytes each, build an
  index list) or a hot/cold split. Rebuild derived arrays per frame rather than syncing
  incrementally.
- Singletons store a handle (`w.player: Handle`), not special slots or an enum table.
- **Cameras and lights are flat entity fields**, not components or nested structs (the fat-struct entity
  of Handmade Hero and Ryan Fleury's megastruct). A kind is which type is set; systems read only the
  fields they need in one linear pass.
  - The fields are `camera_type` and `light_type` (enums), plus `color`, `intensity`, `fov` (degrees),
    `size` (vec3) and `range` (near, far), and `shadow`.
  - Shared fields mean what they mean for each kind (`entity_schema.ini` comments). `fov` is the camera
    fov or the spot cone. `color` × `intensity` is a light's colour, and on a model its colour multiplier
    (`entity_tint`: the per-instance `tint` in the scene shader, and the albedo the probe bake bounces). `size` is the box the entity's projection or volume covers: ortho view height
    in y, the directional shadow area and depth, later volumes. `range` is clip planes, or shadow near and falloff radius.
  - There's no `aspect`: a camera takes it from the target it renders into. `size` never holds model
    bounds, which come from the asset.
  - Something that needs two roles (a flashlight on a camera) is two entities.
  - An entity may have no model. The editor makes cameras and lights visible (`editor_shapes.odin`, `editor_icons.odin`):
    an icon at the entity, drawn on the view's overlay like Unity's gizmo icons, and its shape
    (frustum, light reach) as debug lines, dimmed unless selected.
    - **G** (or the toolbar button) toggles a view's game view (`Editor_View.game_view`), like Unreal.
      It hides everything editor-only there: icons, outlines, selection boxes and the gizmo, which then
      can't be clicked either. Gameplay `debug_line`s stay.
    - Icons are a constant screen size, drawn in front of everything; G hides them. (Distance scaling,
      fading and occlusion rays were tried and cut: more code and special cases than they were worth.)
    - The icon is what you click: it wins over a mesh behind it. Marquee tests it, and F frames it.
    - Icons are drawn from the icon font, so they need no textures. A real billboard sprite is only for
      the game's look.
- Sky is a system with its own params and volumes, not an entity. Things belong in the
  entity array when they have a transform and participate in shared passes.

### Lua boundary

Lua issues commands and queries state. **Lua never holds state** — not for animation, not
for AI, not for sound. Odin is authoritative so script reload can't corrupt anything.

- The whole script API is the `@(lua)` procs in `lua_api_world.odin`, `lua_api_entity.odin` and
  `lua_api_input.odin`: thin wrappers over world-layer procs that take `^World`. World, entity, physics,
  sound and input code knows nothing about Lua. The binding codegen (`src/codegen/codegen_lua_binding.odin`)
  scans for the attribute and marshals params and returns.
- They act on `lua_world()`, the world whose script is running. There is no hidden world: called from an
  engine hook (`引擎.更新`), World/Entity procs log an error and do nothing; engine hooks are for
  session-level logic and Input.
- `World.debug_line(from, to [, color])` draws in every view of the script's world, the game view too.
  The lines live in `World.debug_lines` until the world's next tick (`world_play_tick` clears them), so a
  script redraws what it wants each update and they hold while paused. Gameplay code in Odin uses
  `world_debug_line` the same way.
- `Entity.set_*` write through `entity_writable_field` like files and blimpctl do: no `hidden` fields (but
  `noserialize` game state like `velocity` is writable), string fields are interned asset keys, names stay unique. `World.add` goes through `world_add`.

### Sound

- **Fire-and-forget commands**, not per-frame evaluation. Audio runs on its own thread
  filling buffers ahead of the visual frame.
- Handles only for looping and positional sources. Generation-indexed so stale handles are
  safe no-ops.
- **Voice limiting** is the most important part: fixed pool, steal quietest or oldest.
- **Same-sound coalescing** — minimum interval between instances of one clip.
- Lock-free command queue to the audio thread. Never touch mixer state from the game thread.
- `miniaudio`, not a custom mixer.

Built (`world_sound.odin`):
- miniaudio's `ma_engine` is the mixer and its thread. The lock-free queue is miniaudio's own: every
  `ma_sound_*` call from the game thread is an atomic post its node graph picks up.
- Clips decode at startup (claude/assets.md). A voice is an `ma_sound_init_copy` of a clip, sharing its data.
  `MAX_VOICES` (32). Stealing takes the quietest at the listener (volume × linear falloff), oldest on a tie.
  A new sound quieter than all of them is dropped. Coalescing is `SOUND_COALESCE_SEC` (0.05) per clip; loops are exempt.
- **On entities**: `sound` (a clip key, `widget:sound` picker), `volume`, `sound_flags` (Play On Start, Loop,
  Positional), and `range`: full volume inside x, linear to silent at y. Play starts every enabled entity's
  Play On Start sound. A voice attached to an entity follows it and stops when it goes.
- A voice belongs to a world. A play world's voices pause while it doesn't tick, and stop on Stop or close.
  Edited levels make no sound.
- Lua gets no handles: the entity is the handle. `Entity.play_sound(e)` / `stop_sound(e)` (its own fields),
  `World.play_sound(key [, volume])` (2D), `World.play_sound_at(key, pos [, volume])` (positional,
  `SOUND_DEFAULT_RANGE`).
- Listener: `app_listener` (app.odin) picks the view showing a playing world (the game view first, else
  the active view) and passes its camera — its camera entity if it renders through one — to
  `sound_update`; sound reads no views or UI. miniaudio is right-handed, so z is negated at the boundary.
  Doppler is off.

### Input

`input.odin`: keyboard, mouse and the first gamepad, read from SDL's state once a frame before the game runs.
It's live only in game mode (the app passes it in: `input_update(game_mode)`) with the window focused; otherwise everything reads up/zero, so editor typing never
reaches the game. Lua `Input.down / pressed / released(key)` (SDL scancode names: `"W"`, `"Space"`,
`"Left Shift"`), `mouse_down / mouse_pressed(1–5)`, `mouse_delta()`, `lock_mouse(bool)` (relative mode,
released whenever the editor has the window), `gamepad_axis(name)` (deadzoned), `gamepad_down / pressed(name)`
(SDL's gamepad names).

## Physics — Box3D

Erin Catto's 3D engine. C17, MIT, in Odin's vendor collection. Alpha — expect rough edges
and incomplete documentation.

- Has a built-in **character mover**; no need to write a kinematic capsule controller.
- `identifyEdges = true` when building mesh shapes computes adjacency and suppresses
  internal-edge ghost collisions.
- Meshes cook from `b3MeshDef` into reusable `b3MeshData` with an internal BVH. Do this at
  asset cook time and cache it.
- Baked compound collision exists for the many-instances case — relevant for kitbashed levels.
- **Trimesh for static only.** Convex hulls and capsules for anything dynamic.
- Collision geometry authored separately in Max (`_col` suffix or a dedicated layer) is the
  default. An entity can opt into its render mesh, or its bounds, instead (`collision`, below).
- Give Box3D the general heap allocator rather than fighting it into an arena.

Built so far (`world_physics.odin`): **queries only**. Nothing is simulated and the world is never stepped.
- Per entity, `collision` (enum) picks the shape, cheapest first; it needs a model:
  - None.
  - Box: the model's bounds × scale, a box hull. The cheapest real collider.
  - Collision_Mesh (default): the kit's `<model>_col` mesh, cooked at asset load (claude/assets.md). Authored, so as
    simple as the artist made it. Play logs one warning counting entities whose model has no `_col`.
  - Render_Mesh: every triangle of the model, cooked on first use and cached until the next asset reload
    (`asset_render_collision`). The most expensive; fine for low-poly levels.
- Play builds a Box3D world for the play world: a body per enabled entity with a shape, at its position, rotation
  and scale (shape user data = the entity handle). **Static** entities are static bodies. Anything else is
  **kinematic** and follows its entity every frame (`physics_update`, after the game systems, only when it moved),
  so a scripted drawbridge blocks. Mesh shapes on kinematic bodies are fine for queries; contacts would need hulls.
  Its scale is the one at Play. Freed on Stop; an asset reload rebuilds it. Nothing spawned during play collides yet.
- Box3D's lib is built with its asserts on: `physics_assert` logs one before breaking. It wants unit quaternions to
  tighter precision than a level file's 5 decimals, so body rotations are normalized first.
- Box3D gets the engine's left-handed coordinates as they are. Its CCW rule is "cross(v1 − v0, v2 − v0)
  points out", the engine's own.
- Lua (Odin answers, Lua holds nothing):
  - `World.raycast(origin, dir, dist)` → hit, point, normal, entity.
  - `Entity.move_character(e, delta, radius, height)` → grounded. It's the character mover: a capsule standing on the
    entity's position, collide → `SolvePlanes` → `CastMover`, up to 5 times. Ground is a plane with normal.y ≥ 0.7.
    The entity's own collision is skipped (both callbacks filter on the shape's user data).
    Gravity is part of `delta`; velocity, if a game wants it, is an entity field (schema editor).
- Next when needed: kinematic bodies for moving colliders, dynamic convex/capsule bodies, stepping.

