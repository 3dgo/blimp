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

In a world script the rules are an `if / elseif` chain run every update, and the animation records are the
state Lua can't keep: "attacking" is `Anim.playing(e, "Attack")`, hysteresis is a threshold that depends on
which clip is playing. The chosen rule samples its clip and outputs it; switching clips is the transition
(claude/animation.md). Example: the fox module, `assets/characters/fox.luacn`.

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
    `size` (vec3) and `range` (near, far), and `shadow` with `shadow_cull_near`.
  - Shared fields mean what they mean for each kind (`entity_schema.ini` comments). `fov` is the camera
    fov or the spot cone. `color` × `intensity` is a light's colour, and on a model its colour multiplier
    (`entity_tint`: the per-instance `tint` in the scene shader, which scales the material's emissive too, and the albedo
    the probe bake bounces). `size` is the box the entity's projection or volume covers: ortho view height
    in y, the directional shadow area and depth, a volume's whole box. `range` is clip planes, or a light's falloff (y is also its shadow's far plane); `shadow_cull_near` is
    its shadow's near plane, so a lamp's shade doesn't shadow its own bulb (claude/rendering.md → Shadows).
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
- **Volumes** are a third flat kind: `volume_type` (None, Trigger), the box is `size`, centred on the entity and
  turned with it (scale doesn't apply). The editor draws the box and a type icon. A trigger does nothing by
  itself: Lua asks `Entity.contains(volume, point)` each update (`entity_volume_contains`). No enter/exit
  events or overlap system: polling a handful of boxes is a query, and keeps "what happened last frame" out of
  the engine and out of Lua.
- Sky is a system with its own params and volumes, not an entity. Things belong in the
  entity array when they have a transform and participate in shared passes.

### Lua boundary

Lua issues commands and queries state. **Lua never holds state** — not for animation, not
for AI, not for sound. Odin is authoritative so script reload can't corrupt anything.
World scripts are strict: their env's `__newindex` errors, so assigning an undeclared name stops the script
(a forgotten `local` would otherwise keep state between frames). LuaCN spells `local` as `令` or `本地`.
Every script (world scripts and main.lua) loads through `lua_script_load` (lua.odin): its own env falling back
to _G, its own hook table (`World`/`世界` or `Blimp`/`引擎`), strict, and its own `require` / `引入` taking
project-relative paths (`assets/characters/player`, anywhere under assets/). Modules run in that env, so the strict
rule covers them and two playing worlds never share a module's upvalues; cached per script load only. Modules share
data through entities and parameters passed down, never globals. Any .lua change reruns main.lua and every playing
world's script (which script loaded which module isn't tracked). .luacn converts on hot reload, at engine start and
on every Play; the converter skips unchanged output, so those passes don't trigger a reload.

- The whole script API is the `@(lua)` procs in `lua_api_world.odin`, `lua_api_entity.odin` and
  `lua_api_input.odin`: thin wrappers over world-layer procs that take `^World`. World, entity, physics,
  sound and input code knows nothing about Lua. The binding codegen (`src/codegen/codegen_lua_binding.odin`)
  scans for the attribute and marshals params and returns.
- The same scan writes `assets_engine/scripts/gen_lua_api_defs.lua`, the LuaLS types for those procs (English
  names on `World`, Chinese on `世界`, as the hand-written `lua_*_defs.lua` split them), so completion and hover
  in .lua/.luacn follow the API with no hand edits. A proc's `//` doc comment becomes its hover text: the
  lines before `// zh:` for the English name, from `// zh:` on for the Chinese one. Param and named-return
  names show translated on the Chinese side through one shared table (`lua_name` in codegen_lua_defs.odin),
  so a name means the same thing in every proc. Multi-value returns are named Odin results so completion
  labels them. LuaLS runs with `--locale=zh-cn`, so the standard library's built-in docs are Chinese too.
- They act on `lua_world()`, the world whose script is running. There is no hidden world: called from an
  engine hook (`引擎.更新`), World/Entity procs log an error and do nothing; engine hooks are for
  session-level logic and Input.
- `World.find(name)` is quiet: a miss is an answer (the target is gone). `World.get(name)` is for entities the
  script needs: a miss warns once per name per script load (`Lua_World_Script.missed`), so a rename in the
  editor shows up at Play instead of silently disabling the script.
- A script may keep handles to fixed level pieces in top-level locals set in `start` (via `World.get`). That's a
  cache, not state: handles are generational, so a removed entity's handle goes invalid, and `start` reruns on
  every Play and script reload. Anything that spawns, dies or respawns is looked up each frame with `World.find`,
  since a kept handle never sees a new entity of the same name.
- `World.debug_line(from, to [, color])` draws in every view of the script's world, the game view too.
  The lines live in `World.debug_lines` until the world's next tick (`world_play_tick` clears them), so a
  script redraws what it wants each update and they hold while paused. Gameplay code in Odin uses
  `world_debug_line` the same way.
- **Screen UI** is the world script's `World.ui` / `世界.界面` hook drawing through the `UI` / `界面` table
  (`ui_lua_api.odin`): immediate-mode ImGui wrappers (position, same_line, separator, spacing, text, progress_bar,
  begin/end_window, button, checkbox, slider).
  - The UI layer calls the hook (`ui_view_game_ui`) for every view showing a play world, every frame, paused too.
    It's the one hook outside the world update: `World.ui` can't be in `World.update`, which runs before ImGui's
    frame starts and not at all while paused, where a pause menu has to work. `UI.*` outside the hook logs and does nothing.
  - It's the one place the script API reaches up into the UI layer (CLAUDE.md's Lua rule). World code knows
    nothing of it; nothing is stored on `World`.
  - Lua stays stateless: ImGui keeps hover and drags by label; edited values come from Game or entity fields and
    go back there. The engine closes windows a script left open (or errored inside), so ImGui's stack can't unbalance.
  - Positions and sizes are fractions of the view. A window is an ImGui child of the view's window, so it stays on
    the view, never goes behind it and isn't docked; its pivot is its (x, y), so 0.5, 0.5 centres it.
  - Editor theme and font, drawn after the post chain (crisp, not retro). Drawing the UI into the scene target
    with its own font is a later, separate decision. Images are left out until a UI needs one (texture slots in the ImGui heap).
  - `World.paused()` / `World.set_paused(b)` (`world_pause_toggle`): resume happens in the ui hook.
- `Entity.set_*` write through `entity_writable_field` like files and blimpctl do: no `hidden` fields (but
  `noserialize` game state like `velocity` is writable), string fields are interned asset keys, names stay unique. `World.add` goes through `world_add`.

### Levels

- **Nothing survives a level switch but the game state.** No DontDestroyOnLoad: an entity belongs to its
  world (level arena, Box3D world, voices, generational handles), and moving one between worlds would be a
  hidden lifetime special case. Each level places its own player (and camera); the behaviour is a shared Lua
  module (`assets/characters/player`), so any level plays standalone in the editor.
- **Game state** (`world_game.odin`, Lua `Game` / `游戏`): fixed key slots, each a number or a string, whichever
  was set last (`MAX_GAME_VALUES` 64, inline sbufs, copies by value). A dotted key (`玩家.生命值`) is a path, but
  storage stays flat: only listings group it (`game_sorted` orders paths so a group's keys are adjacent). The Game
  Globals window (claude/editor.md) and blimpctl `globals` show and edit it during play. It lives on the play world and moves to the next one
  on a switch: one play session's lifetime (Play starts it empty, Stop drops it). It's in Odin, not a Lua
  table in main.lua, because Lua holds no state: hot reload reruns every script, engine hooks outlive Stop,
  and nothing else (blimpctl, a save file) could read it. A save game is this, written to a file, later.
- **Switching**: `World.switch_level(path)` only records `w.next_level`. `app_process_level_switches`
  (`app_lifecycle.odin`, at frame start before `app_process_closes`) stops the old play world's runtime,
  loads the level into a new play world in its place (`world_play_switch`) and starts its runtime like
  Play. The old one closes through the normal close path. The edited level is never involved (claude/editor.md).
- **Entries** are plain entities in the destination level. The leaving script writes the entry's name into
  the game state; the arriving `start` moves the player there and clears the key, so a hot reload's rerun of
  `start` doesn't pull the player back. Velocity and animation don't carry; a fade would hide the cut.
- **Pickups** (`assets/scripts/coins`): numbered entities (`金币_1`…), hidden when taken, never removed (a gap would
  end the numbered lookup). The total and one key per coin (level name in it) live in the game state; `start`
  re-hides taken ones, since the arriving level is loaded fresh from its file.
- The player's size is the player entity's `scale.x`: the module's distances and speeds are for scale 1 (the
  miniature castle) and scale with it (the office player is 4).

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
It's live only while the game view has the focus (the app passes it in: `input_update(ui_game_has_input())`; always in
a release build) and the OS window has it too; otherwise everything reads up/zero, so editor typing never
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
  - Collision_Mesh: the kit's `<model>_col` mesh, cooked at asset load (claude/assets.md). Authored, so as
    simple as the artist made it. Play logs one warning counting entities whose model has no `_col`.
  - Render_Mesh (default): every triangle of the model, cooked on first use and cached until the next asset reload
    (`asset_render_collision`). The most expensive; fine for low-poly levels, which is why it's the default: no
    `_col` to author before things collide.
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

