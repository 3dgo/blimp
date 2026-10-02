# Memory and arenas


Group arenas **by lifetime first** — an arena holding two lifetimes is a leak. Within a
single lifetime a subsystem may own its own arena when that fits: e.g. the asset system
owns one permanent arena for all its data (freed in a single `arena_destroy`), and a
self-contained step may spin up its own scratch arena. Don't split one lifetime across
several arenas by data *category* (model vs image vs id tables) — that buys nothing and
complicates teardown.

| Arena | Holds | Reset |
|---|---|---|
| permanent | loaded meshes, textures, mesh/material tables | never |
| level | entities, mesh instances, material overrides, collision | level unload |
| probe grid | a world's baked probes (`Probe_Grid.arena`) | rebake, level unload |
| frame | poses, visible lists, command staging | frame start (double-buffered if GPU reads) |
| scratch | short-scope working memory | scope exit (`context.temp_allocator`) |

- Prefer `core:mem/virtual` `Arena`. `arena_init_static` for fixed budgets (overflow
  becomes an error by design), `arena_init_growing` where growth is genuinely needed.
  `Arena_Temp` for nesting save-points.
- **Dynamic arrays in arenas strand memory on grow** — unless the array is the arena's
  last allocation, where `resize` extends in place. Reserve capacity up front where the
  count is known (the entity handle map gets a fixed cap in the level arena). Where it
  isn't (asset load), accept the transient stranding and report real size with a
  `len × size_of` helper rather than the arena's used bytes.
- `delete` on a nil slice is a no-op. Nil means "owns nothing" — unconditional cleanup is fine.
- The fixed-budget arenas (frame, temp) get a panic-on-failure wrapper so exhaustion fails
  loudly with a stack trace and no call-site checks; it formats its message into a stack
  buffer, since it also wraps `temp` and must not allocate to report. `perm` is the
  `Tracking_Allocator`→heap directly, no guard — the OS heap won't realistically run dry.
  `mem.Tracking_Allocator` in debug.
- The frame arena is **single-buffered for now**: frame data is CPU-only staging copied
  into GPU upload buffers before submit, so the GPU never reads the arena itself. Rotate
  per-flight (reset after the frame fence, indexed by the renderer's frame slot) only once
  frame data becomes GPU-visible.
- Pools for high-churn individual lifetimes (particles). General heap for third-party
  libraries (Box3D) and editor state. No exotic allocators.

