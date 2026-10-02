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
    fov or the spot cone. `size` is the box the entity's projection or volume covers: ortho view height
    in y, the directional shadow area and depth, later volumes. `range` is clip planes, or shadow near and falloff radius.
  - There's no `aspect`: a camera takes it from the target it renders into. `size` never holds model
    bounds, which come from the asset.
  - Something that needs two roles (a flashlight on a camera) is two entities.
  - An entity may have no model. The editor makes cameras and lights visible (`editor_shapes.odin`):
    an icon at the entity, drawn on the view's overlay like Unity's gizmo icons, and its shape
    (frustum, light reach) as debug lines, dimmed unless selected.
    - **G** (or the toolbar button) toggles a view's game view (`Editor_View.game_view`), like Unreal.
      It hides everything editor-only there: icons, outlines, selection boxes and the gizmo, which then
      can't be clicked either. Gameplay `debug_line`s stay.
    - Icons scale for a city of lights. Each has a world size, so it shrinks with distance (clamped),
      fades out with distance, and hides when geometry blocks it.
    - Blocking is a CPU ray against the picking BVH, up to `EDITOR_ICON_RAYS_PER_FRAME` per view per
      frame, taking turns. Selected icons always stay faintly visible.
    - The icon is what you click: it wins over a mesh behind it. Marquee tests it, and F frames it.
    - Icons are drawn from the icon font, so they need no textures. A real billboard sprite is only for
      the game's look.
- Sky is a system with its own params and volumes, not an entity. Things belong in the
  entity array when they have a transform and participate in shared passes.

### Lua boundary

Lua issues commands and queries state. **Lua never holds state** — not for animation, not
for AI, not for sound. Odin is authoritative so script reload can't corrupt anything.

### Sound

- **Fire-and-forget commands**, not per-frame evaluation. Audio runs on its own thread
  filling buffers ahead of the visual frame.
- Handles only for looping and positional sources. Generation-indexed so stale handles are
  safe no-ops.
- **Voice limiting** is the most important part: fixed pool, steal quietest or oldest.
- **Same-sound coalescing** — minimum interval between instances of one clip.
- Lock-free command queue to the audio thread. Never touch mixer state from the game thread.
- `miniaudio`, not a custom mixer.

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
- Collision geometry authored separately in Max (`_col` suffix or a dedicated layer), not
  derived from render meshes.
- Give Box3D the general heap allocator rather than fighting it into an arena.

