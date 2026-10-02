# Animation


Immediate-mode tree, evaluated per frame. Gameplay owns decisions; the system owns time and
pose evaluation.

```odin
loco  := blend(ctx, sample(ctx, "walk", dt), sample(ctx, "run", dt), speed_ratio)
upper := additive(ctx, sample(ctx, "pistol_aim", dt), sample(ctx, "pistol_fire", dt), fire_weight)
final := layer(ctx, loco, upper, skel.masks.upper_body)
```

- Poses live on the frame arena; ops write into caller-provided output.
- **Local space throughout**, converted to model space once at the end. Additive and masking
  both require local space.
- **Keyed state, ImGui-style.** `sample("walk")` looks up or creates a `{time, prev_time}`
  record keyed by clip. Touched records advance, untouched are dropped — so snapping to a
  death animation needs no cleanup. Keys must be unique per usage; assert on double-touch
  in one frame.
- **`blend(a, b, weight)`, not `crossfade`.** A fade has duration and is inherently stateful.
  Prefer **inertialization**: snap to the new clip and decay the pose *difference* to zero.
  One clip sampled after the transition, no fade weights, no double event firing.
- Blend masks are precomputed per-joint weight arrays on the skeleton, feathered at the
  boundary. A hard cut at `spine_01` looks wrong.

### Events

- Sorted `{time, name}` array per clip. Fire those in `(prev_time, new_time]`. Dispatch to
  Lua by name.
- **Loop wrap** splits into `prev→end` and `0→new`. Forgetting this silently drops events
  every loop.
- **Weight threshold** (~0.5), evaluated at end of frame once effective weights are known,
  or cross-fades double every footstep.
- **Seek vs play**: seeking sets `time` and `prev_time` together and fires nothing. Needed
  for restart, respawn, cutscene scrubbing, timeline dragging.
- Clamp dt at frame top, or cap events per clip — resuming from a breakpoint otherwise
  plays forty footsteps.
- Authored in a text sidecar (`footstep_l 0.23`), hot-reloaded. Max note tracks don't
  survive glTF export.

### Procedural layer

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

### Optimizations that don't change the API

Integer clip IDs instead of string keys, weight-threshold culling, evaluation LOD for
distant characters, and a recorded instruction buffer enabling cross-character batching and
worker-thread evaluation.

