# Animation

Immediate-mode tree, evaluated per tick. Gameplay owns decisions; the system owns time and
pose evaluation. The tree is written in the world script (Lua), one call per op:

```lua
local loco  = Anim.sample(e, "Walk", speed / Anim.root_speed(e, "Walk"))
local upper = Anim.sample(e, "Wave")
Anim.output(e, Anim.layer(loco, upper, "b_Spine01_02", wave_weight))
```

- **A character is an ordinary entity** with a skinned `model`, moved by `move_character` and posed by its
  script. No character type, no component, no state machine asset. Its state is the gameplay.md rule list,
  written in Lua; the records below are the state Lua isn't allowed to hold ("attacking" is
  `Anim.playing(e, "Attack")`). Example: the fox module `assets/characters/fox.luacn`, driven by castle.luacn (docs/lua.md §12.8).
- Poses live on the frame arena; ops are eager and return a new pose.
- **Local space throughout**, converted to model space once in `output`. Additive and masking
  both require local space.
- **Keyed state, ImGui-style.** `sample(e, "Walk")` looks up or creates a `{time, prev_time}`
  record keyed by (entity, clip). Touched records advance, untouched are dropped at the end of the tick — so
  snapping to a death animation needs no cleanup. One clip twice on one entity in a tick logs an error (two
  usages of a clip would need a key argument; add it when a game needs it).
- **`blend(a, b, weight)`, not `crossfade`.** A fade has duration and is inherently stateful.
  **Inertialization** instead: a record that's new this tick (or seeked) on an entity that output last
  tick starts a transition — per joint, offset = what was shown ⊖ the new pose, decayed to zero by a
  critically damped spring (halflife = blend_time / 2, default 0.2 s). The offset starts at rest (the new
  clip's velocity isn't known; assuming zero would add motion). One clip sampled after the switch, no fade
  weights, no double event firing. Walk↔run switches; it isn't phase-synced (add sync when a game needs it).
- Layer masks are computed per call from a joint name: that joint's subtree, feathered over
  `MASK_FEATHER` (2) joints below it. Nothing stored, since assets don't change.

### Assets (`asset_anim.odin`, claude/assets.md)

- A **Skeleton** per glTF skin: joints reordered parent-before-child (`MAX_JOINTS` 128, u8 indices),
  names, rest pose, `inv_bind`, `root_parent` (the rotation/scale above the top joints, e.g. a DCC's Z-up
  node), and `clips` (short name → clip). Clips in the skin's own file bind to it; animation-only files
  (binding by joint name) wait until a real one exists.
- **The rest pose is baked into the vertices** (`Σ wⱼ · Gⱼ_rest · IBMⱼ`), with `inv_bind = inverse(Gⱼ_rest)`.
  An unskinned draw of the mesh is its rest pose — the editor shows that, and the shader skips skinning when
  an instance has no bones. Robust to whatever an exporter put in its IBMs.
- **Clips are resampled at import** to about `CLIP_RATE` (30 Hz), every joint every frame (STEP, LINEAR,
  CUBICSPLINE honoured). Sampling is two frames and a lerp; no key search.
- **In place:** the shallowest translated joint's straight-line XZ travel over the clip is removed (its sway
  stays) and kept as `root_speed`; gameplay moves the capsule, and `speed / root_speed` keeps feet planted.
- Engine space throughout: the glTF's X reflection is `S·M·S` on every joint transform
  (`t → (-x, y, z)`, `q → (x, -y, -z, w)`).

### Runtime (`world_anim.odin`)

- `Anim_World` per play world (allocated at Play like physics, freed on Stop, reset on asset reload).
  Fixed budgets: `MAX_ANIMATED` characters (slot by entity handle index), `MAX_RECORDS` per character,
  `MAX_POSES` per tick. A character exists while something outputs a pose for it.
- Frame order (`app_run`): scripts sample and output → `anim_update` (entities with an `anim` field and no
  output loop that clip; characters with no output go back to the rest pose; events fire; untouched records
  drop) → `lua_worlds_anim_events` → render reads each character's skin matrices. Only on ticking frames:
  paused worlds hold their pose.
- `output` computes model and skin matrices immediately, so `Anim.joint` after it is this tick's.
- **Stepped motion:** `World_Settings.anim_fps` (0 = every frame). Skin matrices are only recomputed on whole
  steps of world time; clip time, events and transitions stay continuous. A world setting, not a Retro one:
  poses are world state, the Retro look is per view.
- The entity `anim` field (a clip short name) is the no-script case: ambient NPCs, props.

### Clips file

3ds Max has one timeline per scene, so a character's actions go on it one after another and the engine cuts
them apart. `<kit>.clips` next to the glTF (`knight.max` → `knight.gltf` + `knight.clips`), hot-reloaded with
the assets, says how (`asset_import_clips`):

```
fps 30
[Idle 0 30]        # clip = timeline frames 0–30 of the glTF's first animation
[Walk 40 64]
footstep 46        # event at a frame of the same timeline
[Survey]           # no range: the glTF's own animation of that name, whole; events count from its start
```

- With ranges, the animation they're cut from isn't a clip itself; any other animations stay whole clips.
  Without the file, every animation is a clip, whole, with no events.
- Frames, not seconds: they're what an artist reads off the time slider. glTF time 0 is the first exported
  frame, so the timeline starts at 0.
- `tools/max/blimp_clips.ms` writes it (Chinese UI; in `scripts\startup` it adds a Blimp menu). Clips and
  events are both Max **time tags**, so they show on the time slider: a clip is a `▶Walk` tag at its first frame
  and runs to the frame before the next `▶` tag (splitting at the slider, not start/end pairs to keep in step);
  any other tag is an event in the clip it falls in. Every dialog change and every .max save rewrites the file,
  which keeps explicit ranges. Saved UTF-8 with a BOM (Max reads BOM-less scripts in the system code page).
  `FrameTagManager` signatures were guessed: `CreateNewTag` takes (name, time) in Max 2027; the time getters
  and setters try both forms.
- One file per character, not one per clip (option 2, animation-only `knight@walk.gltf` files binding by joint
  name, waits until re-exporting the whole character hurts).

### Events

- Sorted `{time, name}` array per clip, from the clips file. Max note tracks don't survive glTF export.
- Fire those in `(prev_time, new_time]`, after the tick's outputs, to the world script's
  `World.anim_event(e, name)` / `世界.动画事件`.
- **Loop wrap** splits into `prev→end` and `0→new`. Forgetting this silently drops events
  every loop. A record's first tick covers `[0, 0]`, so an event at 0 fires.
- **Weight threshold** (`EVENT_WEIGHT` 0.5): a record's share of the output, summed through the ops, at the
  end of the tick, or cross-fades double every footstep.
- **Seek vs play**: seeking sets `time` and `prev_time` together and fires nothing. Needed
  for restart, respawn, cutscene scrubbing, timeline dragging. Played backwards: no events.
- dt is clamped at frame top (`timer_game_delta_sec`, 0.1 s) — resuming from a breakpoint otherwise
  plays forty footsteps.

### Procedural layer (designed, not built)

Runs **after** blending, in **model space**, before skinning matrices.

```odin
final = spring_chain(ctx, final, "ponytail", skel.chains.ponytail, stiffness = 40, damping = 6)
final = look_at(ctx, final, "head", target_pos, weight = aim_weight)
```

- Keyed on **site name**, not bone — two solvers on one bone are separate entries. Call
  order is the semantics when they overlap.
- World-space inputs (root velocity, impulses) live on the context, not threaded through
  every call. Impulses arrive as commands: `anim.add_impulse(char, "weapon_recoil", force)`.
- **Look-at** stores a smoothed *direction* (spring, not lerp — the settle reads better).
  Weight is a per-frame gameplay input. Angle limits and distribution across chest/neck/head
  are stateless; distribution weights sum to 1, unlike blend masks.
- A **shared per-joint `{pos, vel}` array** across solvers is a reasonable simplification —
  solvers usually own disjoint joints, and teleport reset becomes one operation.
- Every solver needs an **`initialized` flag**: seed from the input pose on first evaluation
  or chains snap in from the origin.
- **Reset procedural state on teleport** or hair flies across the level for a frame.

### Also designed, not built

Additive clips (`_add` suffix, baked as the difference from frame 0), phase sync for locomotion blends,
animation-only glTF files, an editor clip preview, attachments (an entity following a joint) as a field.

### Optimizations that don't change the API

Weight-threshold culling, evaluation LOD for distant characters, and a recorded instruction buffer
enabling cross-character batching and worker-thread evaluation.
