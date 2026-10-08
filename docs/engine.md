# Blimp engine guide

How the engine is put together: what it's for, why it's built the way it is, how a frame and the
main user actions flow through it, and what every part of `src/` does. Read it top to bottom once;
later, jump to a subsystem or the file map.

The design notes in `claude/` hold the full detail and the rules for each area. This guide is the
map. Where it says *see* a file, that file has the specifics.

---

## 1. What Blimp is

Blimp is a custom game engine written in **Odin** on **DirectX 12**, with its own editor. It's a solo
project, partly for learning. The target look is **PS1-era "without the hardware limitations"**: low
resolution, vertex jitter, affine textures, 5-bit colour with dither, hard shadows, baked light, all
done on purpose on modern hardware rather than forced by it.

Four principles shape almost every decision:

1. **Simplest thing that solves the actual problem.** No scaffolding for systems that don't exist yet.
   Speculative generality counts as a bug.
2. **Precomputed and baked over realtime and screen-space.** It fits the look (PS1 games baked
   everything) and keeps the scope small.
3. **No hidden cost.** Lifetimes, allocations and per-frame work are visible in the code. Tedious and
   explicit beats clever and implicit.
4. **Flat data, linear passes.** One fat `Entity` struct and top-down loops over flat arrays, several
   passes a frame if needed. No ECS, no components, no class hierarchies.

---

## 2. Design decisions and why

Each decision below is settled. The reason is what makes it worth keeping, and the trade-off is what
it costs.

| Decision | Why | Trade-off |
|---|---|---|
| **One fat `Entity` struct** (cameras and lights are flat fields like `camera_type`, `light_type`, `fov`, `range`) | Every system reads the fields it needs in one linear pass. No lookups, no component plumbing. Adding a field is one line in a schema. | Every entity carries every field. A thing with two roles (a flashlight on a camera) is two entities. |
| **Schema-generated entity** (`entity_schema.ini` → `gen_entity.odin`) | The struct, defaults and English/Chinese labels have one source. The in-engine schema editor can add a field without hand-writing UI. | You edit the schema, never the generated file, and rebuild to see a change. |
| **GPU-driven, bindless, indirect draws** | Shaders reach every buffer and texture by heap index. Draw commands live in a buffer and run through `ExecuteIndirect`, so moving culling to a compute pass later changes only who writes that buffer. | Needs Resource Binding Tier 3 (about 2015 GPUs); there's no fallback path. |
| **Simple forward rendering**, not clustered | Clustered pays off at hundreds of dynamic lights; this game has a few. | Many realtime lights would be slow. |
| **Baked probe lighting** (L2 SH + depth, DDGI format) for indirect; realtime direct with hard shadows | Fits the look, lights static and moving geometry alike, needs no lightmap UVs or atlas packing. The DDGI format leaves room for a realtime update later. | Probes are coarse; bakes take seconds. Static shadow caching isn't done yet. |
| **Reversed-Z**, float HDR target, quantize only at the end | Depth precision everywhere; the retro quantize is a deliberate last step, not an accident of format. | None worth noting. |
| **Left-handed, Y-up, +Z forward, clockwise fronts.** glTF import reflects −X *and* swaps winding | One convention through the whole engine. Both import steps are needed for correct front faces. | Every import pays the conversion. |
| **Assets load at init and never change at runtime** | No streaming, no manifests, no meta files, no UUIDs. Keys are project paths plus a name (`assets/models/castle.gltf:flag001`). Debug hot reload just rebuilds everything, as init would. | Everything must fit in memory. Fine for this scope. |
| **A glTF file is a kit** | Artists author related models together; the editor opens a kit as a world to copy models out of. | Kits are the unit of import, so textures can be shared across kits only by path. |
| **Arenas grouped by lifetime** (permanent, level, frame, scratch) | Freeing is one call per lifetime; leaks show up as an arena holding two lifetimes. | Dynamic arrays in arenas strand memory on growth, so reserve up front. |
| **Worlds are instantiable values**, systems take `^World` | Any number of levels and kits open at once; play mode is just another world. | Every system has to be told which world. |
| **Play mode runs a copy of the level** | Nothing the game does can leak into the level. Forgetting to reset something can't silently corrupt it. | Each Play copies the entity map (cheap: a fixed-size value). |
| **Undo is whole-world snapshots**, and it drives unsaved tracking | No per-operation undo code; restoring brings back exact handles. Every edit calls `undo_push` first, so "dirty" falls out of it. | One snapshot is ~600 KB at the entity cap, so history is capped at 64 steps. |
| **Lua issues commands and queries; it never holds state** | Odin is authoritative, so reloading a script can't corrupt anything. | Scripts keep state in entity fields, not Lua variables. |
| **Chinese-first localization and LuaCN** | The game's scripters read Chinese; every UI string has EN and ZH, and LuaCN is Lua with Chinese keywords. | Every UI string needs both languages. |
| **Strict layering** (§3) and one lifecycle file | Each part of the code can be read knowing what it may touch. Sequences that touch everything are written out once, in order. | A few more procs in `app_lifecycle.odin`, rather than callbacks. |
| **`Entity.selected` lives on the entity** — the one piece of editor state on a core struct | Undo snapshots carry the selection for free; delete and paste need no bookkeeping. | It must stay `hidden, noserialize` so it never reaches files or the clipboard. |

---

## 3. The big picture

### Layers

`src/` is one Odin package. Files are grouped by prefix, and the prefixes form layers. **A layer only
calls the layers below it.**

```
 app_      the driver: frame loop, lifecycle orchestration, blimpctl, hot reload, RenderDoc
   ↓
 ui_       ImGui windows: viewports, panels, inspector, settings windows
   ↓
 editor_   editing logic: selection, undo, gizmo, camera navigation, bake, schema, overlay
   ↓
 lua_      the script runtime and the script API (lua_api_*)
   ↓
 render_   DX12 renderer: reads worlds, never writes them
   ↓
 world_    worlds and what runs in them: registry, play mode, physics, sound, light groups, probes, level files
   ↓
 asset_    assets: glTF kits, meshes, images, BVHs, collision
   ↓
 (no prefix)  foundation: app globals, basics, time, serialize, entity, input, loc, search, game_settings
```

`gen_` files are generated (entity struct, Lua bindings, pinyin table) and belong to whatever layer
uses them. `src/dx` (the DX12 wrapper) and `src/common` (shared helpers, LuaCN) are separate packages.

What the rule buys you:

- **The renderer knows nothing about the editor or UI.** It doesn't call `ui_draw`; the app draws the
  UI between the renderer's calls. It doesn't call editor code for debug lines; the app collects them
  first.
- **World code knows nothing about Lua, the editor or the UI.** The script API lives in
  `lua_api_*.odin` as thin wrappers; world procs take `^World` and don't care who calls them.
- **Data flows down.** Input is told whether the game owns the window (`input_update(game_mode)`); sound
  is handed its listener (`sound_update(listener)`). Neither reaches up into the UI to find out.

The one place that calls across every layer is **`app_lifecycle.odin`**. Opening a world, playing,
stopping, closing and reloading assets each touch the world lists, the renderer, physics, sound, Lua,
undo and the UI. Each is one proc there that does all of it in order, so the whole sequence reads top
to bottom.

### Core types at a glance

| Type | Layer | What it is |
|---|---|---|
| `Entity` | foundation (generated) | One placed thing: transform, model, flags, camera/light/sound/collision fields. |
| `World` | world | A level, kit or play copy: the entity handle map, settings, and its runtime state (render mirror, physics, script, probes, play links). |
| `Render_View` | render | One viewport onto a world: render target, free camera, optional camera entity, frame constants. |
| `World_Render` | render | A world's per-frame GPU mirror: transforms, mesh instances, lights, draw commands, shadow maps, probe buffers. |
| `Asset_Buffers` | render | The one GPU copy of all asset geometry, materials and textures, shared by every world. |
| `Editor_World` | editor | The editor's side of a world: active entity, Shift-click anchor, unsaved tracking. |
| `Editor_View` | editor | The editor's side of a view: screen rect, hover, navigation, gizmo, marquee, icon state, window flags. |
| `Settings_Window` | ui | Which world a settings window shows, and its in-progress undo step. |

---

## 4. Lifecycle

### Startup (`app_init`)

1. Timer, loggers, allocators (perm heap with a tracker, frame arena, temp arena), global context.
2. Move to the project root (walk up from the exe until `assets/` is found), so every path is
   project-relative.
3. SDL and the window.
4. `asset_system_load`: every glTF kit, its meshes and images, mesh BVHs and collision.
5. `lua_init`: the Lua state, `setup.lua`, the generated bindings, then `main.lua` (engine hooks).
6. `sound_init`: miniaudio and every sound clip.
7. `renderdoc_init` (before the device, so RenderDoc can hook it), then `renderer_dx_init`: device,
   queues, heaps, pipelines, and the shared asset buffers uploaded.
8. `game_settings_load` (`game.ini`), `ui_init`, `remote_init` (blimpctl), hot reload watchers (debug).
9. `ui_game_start` opens Game Settings' start level. A release build plays it straight away in game
   mode.

### One frame (`app_run`)

`app_run` is the frame timeline; read it as the authority. In order:

| Step | Call | What happens |
|---|---|---|
| 1 | `timer_frame_begin` | The frame's clock is sampled once, so every system agrees on time. Temp and frame arenas reset. |
| 2 | `hot_reload_update` (debug) | Changed files reload: assets, shaders, sounds, scripts. |
| 3 | SDL events | Resize, quit (through the unsaved prompt), F9 restart; everything goes to ImGui too. |
| 4 | `app_process_closes` | Worlds and views closed last frame are torn down, after the GPU idles. |
| 5 | `input_update(game_mode)` | Keyboard, mouse, gamepad, live only in game mode. |
| 6 | `lua_update` | The engine hook `引擎.更新` / `Blimp.update`. |
| 7 | `world_play_tick` | Each play world decides whether it advances this frame (`ticks`, honouring pause and F10 step) and advances its game clock. |
| 8 | `lua_worlds_update` | Each play world's script: loads (running `start`) on the first frame, then `update(dt)` on ticking frames. |
| 9 | `physics_update` | Kinematic bodies follow entities the game moved. |
| 10 | `sound_update(app_listener())` | Listener placed, attached voices follow, paused worlds pause their voices. |
| 11 | `remote_poll` | blimpctl commands run, between frames. |
| 12 | `ui_update` | The editor's whole ImGui frame (or just the game view in game mode). Edits happen here. |
| 13 | `ui_view_debug_lines` | Each view's editor lines (selection boxes, light reach, probes) go into the debug line list. |
| 14 | `renderer_dx_draw_frame` | Worlds staged, shadows, every view's scene, post and debug lines; backbuffer cleared and bound. |
| 15 | `ui_draw` | ImGui's draw data into the backbuffer. |
| 16 | `renderer_dx_submit` | UI screenshot if asked, end-of-frame state, submit. |
| 17 | `ui_render_platform_windows`, `renderer_dx_present` | Windows dragged out of the main one; present and signal. |

Game systems check `w.ticks`, never `paused`, so a single F10 step advances all of them by exactly one
frame.

### Shutdown (`app_shutdown`)

Wait for the GPU, stop blimpctl and the file watchers, `app_close_all` (every world and view through
the normal close path), then sound, input, undo, Lua, UI, renderer and assets, and finally an audit
that logs any unfreed allocation.

---

## 5. Core concepts

### Worlds, views and their editor sides

A **World** is a value: an entity handle map plus settings and runtime state. Any number are open,
each individually allocated in `worlds` (`world_registry.odin`) so pointers stay stable. Three kinds,
one type:

- a **scene** world, opened from a `.level` file, saveable;
- a **kit** world, opened from a glTF (one entity per mesh node), not saveable;
- a **play** world, the running copy of a level during Play.

A **Render_View** is a viewport onto a world. Many views can share one world; the world's draw data is
built once per frame and shared. The **active view** is the one you last focused; its world receives
Ctrl+C/V.

The editor keeps its own state beside these, never inside them: an **Editor_World** per world (active
entity, Shift-click anchor, unsaved state ids) and an **Editor_View** per view (screen rect, navigation,
gizmo, marquee, window flags). Both are created on first use and freed when their world
or view closes.

### Entities and the schema

`entity_schema.ini` declares every `Entity` field: its type, default, tags, inspector section, EN/ZH
labels and a `note`. Codegen writes `gen_entity.odin`: the struct (with notes as comments), the enums
and flag sets, `entity_apply_defaults`, and the label tables. The schema editor window edits the same
file and rebuilds the engine on Apply.

Tags drive behaviour: `noserialize` (never saved or copied: the handle, the selection flag), `hidden`
(not in the inspector), `identity` (never copied by multi-edit: the name), `widget:model` / `widget:sound` / `widget:icon` (how the inspector edits it).

Entity predicates name the rule each system applies, instead of raw flag tests:

| Predicate | Meaning | Used by |
|---|---|---|
| `entity_enabled` | Enabled | physics, Play On Start sounds, the game camera |
| `entity_editor_visible` | enabled and not hidden | camera/light icons and shapes |
| `entity_drawn` | renderable, enabled, not hidden | the renderer, picking, marquee |
| `entity_bakes` | drawn, static, Cast Indirect | the probe baker |

### Model → Mesh → Mesh_Instance → draw command

An entity names a **Model** (a CPU list of meshes, from a kit). Each **Mesh** is one glTF primitive. An
entity × mesh pair is a **Mesh_Instance**. Each frame every drawn mesh instance becomes a **draw
command**, grouped by blend mode. Undrawn entities keep their transforms and instances, so indices
don't shift when something is hidden.

### Asset keys

Every asset reference is a string key: a project-relative path, plus a name for things inside a file
(`assets/models/castle.gltf:flag001`, `assets/sounds/wind.wav`). Keys are **interned**
(`asset_intern`) in an arena that outlives hot reloads, so entities, undo snapshots and the clipboard
stay valid when assets reload. Strings decoded from text are temporary; anything that keeps a key
interns it, and `world_add` does that for every entity.

### Memory

| Lifetime | Where | Freed |
|---|---|---|
| permanent | `app.allocators.perm` (tracked heap), the asset arena, the key arena | never (assets: on reload) |
| level | a `World` (its entity map is a fixed-size value inside it) and its probe arena | when the world closes |
| frame | `app.allocators.frame` | every frame (animation poses) |
| scratch | `context.temp_allocator` | every frame |

Procs that return memory take an allocator parameter; procs that only need working space use scratch.

### Coordinates and conventions

Left-handed, Y-up, +Z forward, clockwise front faces, reversed-Z. GPU structs pad to 16 bytes with
named fields and assert their layout matches the shader. UI text goes through `tr(.Key)` with EN and ZH
on one row of `loc.odin`; logs, keys and paths stay ASCII English.

---

## 6. Overall logic: end-to-end walkthroughs

Each walkthrough follows one action through every file it touches.

### Opening a level

1. The Worlds window (`ui_worlds.odin`) calls `app_open_scene(path)`.
2. `world_open_scene` (`world_registry.odin`) allocates a `World`, `world_init` sets default settings
   and the probe arena, and `scene_load` (`world_scene.odin`) reads the file:
   - `[world]` → `World_Settings` via `ini_read_section` (`serialize.odin`);
   - each `[entity]` block → `entity_default()` then `deserialize_field` per line, then `world_add`,
     which interns asset keys, makes the name unique and adds it to the handle map;
   - the `.probes` sidecar → `probe_grid_load` (`world_probes.odin`).
3. Back in `app_open_scene`: `world_render_create` builds the world's GPU mirror, `app_view_open`
   creates a `Render_View` framing the world (`camera_frame_world`), and `ui_host_open` opens its
   window with an entity list and inspector docked beside the viewport.

### How an entity ends up on screen

1. **Each frame**, `renderer_dx_draw_frame` calls `world_render_upload` for every world.
2. `buffers_build_scene` (`render_buffers.odin`) walks the entities once:
   - drawn lights → `GPU_Light` (scaled by their light group, `world_light_groups.odin`) and shadow
     slices (`light_shadow_assign`, `render_shadows.odin`);
   - every entity with a model → a transform; each of its meshes → a `Mesh_Instance_Data` with the
     material, the resolved shading model (`entity_shading`) and tint (`entity_tint`);
   - drawn instances → draw commands, bucketed by blend: Opaque, Cutout, Alpha (sorted back to front),
     Additive;
   - a hash of everything that casts shadows, for the shadow cache.
3. The arrays are staged on the copy queue; per-view `Frame_Constants` are written
   (`render_view_update_constants`): camera (or the camera entity in game mode), buffer slots, retro
   settings, exposure, fog, probe grid.
4. **Shadows**: `render_shadows_draw` renders shadow slices depth-only from the same indirect commands
   (Opaque and Cutout). Slices are cached: only one whose light moved, or every one when a caster moved,
   is redrawn; a still level draws none.
5. **Scene**: `render_view_draw` clears the view's HDR target and runs one `ExecuteIndirect` per blend.
   `scene.slang` reads the instance through the root constant, fetches transform, mesh and material
   bindlessly, applies PS1 vertex snap, and `shading.slang` lights the pixel (direct lights, hard
   shadows, probe irradiance with visibility).
6. **Post**: `render_post_draw` (`post.slang`) adds fog along each pixel's ray (distance and height fog,
   lamp halos; docs/fog.md), tonemaps every pixel, background included, quantizes with dither into the signal, optionally blurs bloom, and upscales
   (point, or a CRT model) into the display target.
7. **Debug lines** draw on the display target after post, so their colours stay exact: the game's own
   (`World.debug_line`) in every view, the editor's in editor views.
8. **UI**: the view's display target is an ImGui image in its window; `ui_draw` puts it on screen.

### An editor edit

Take dragging an entity with the gizmo:

1. Click: `view_pick` (`editor_selection.odin`) finds what's under the mouse (an icon wins, else the
   nearest drawn mesh along `view_mouse_ray`), and `selection_click` sets `Entity.selected` and
   `Editor_World.active`. Selection isn't an edit: no undo step, the world isn't dirtied.
2. Drag: `gizmo_update` (`editor_gizmo.odin`) hit-tests its handles in screen space. On the first
   frame that changes anything it calls `undo_push(w)`: the whole entity map is snapshotted and the world
   gets a fresh state id.
3. Each frame `gizmo_apply` writes the new transforms to every selected entity. Esc calls
   `undo_revert_last` instead.
4. The world is now dirty: its state id differs from the saved one (`world_dirty`, `editor_world.odin`),
   so its tab shows `*` and Save enables.
5. Save (`world_save`) writes the `.level` (`scene_save`), and the saved id catches up. Undoing back to
   that point makes the world clean again.

Edits noticed after the fact (inspector widgets, settings windows) snapshot with the pre-edit value
instead: `undo_push_edited`, and `settings_window_track_edit` for the settings windows.

### Pressing Play, and Stop

1. F5 or the toolbar calls `ui_play`, which calls `app_play(world)` then enters game mode.
2. `app_play` (`app_lifecycle.odin`):
   - `world_play_copy` makes a play world with the level's entities, settings and light-group overrides,
     registers it, and switches every view of the level to it;
   - `editor_world_copy` carries over the active entity;
   - `world_render_create` gives it a GPU mirror;
   - `ui_retarget_world` moves pinned panels and settings windows to it;
   - `physics_world_start` builds Box3D bodies; `sound_world_start` starts Play On Start sounds.
3. Next frame `lua_worlds_update` loads the world's script and runs its `start` hook. From then on,
   every ticking frame runs `update(dt)`, physics follows, sound follows.
4. Game mode (`ui_game.odin`) makes that view the whole window, rendered through the first enabled
   camera entity (`world_game_camera`). F8 toggles back to the editor while the game keeps running.
5. Stop (F7) calls `app_stop`: script, voices and physics stop, `world_play_discard` switches the views
   back and queues the copy to close, `ui_retarget_world` points the UI back at the level. Next frame
   `app_process_closes` frees the copy. The level was never touched.

### A Lua call

A world script calls `World.raycast(origin, dir, 50)`:

1. Lua calls the C function the bindings registered: `_lua_world_raycast_lua` in `gen_lua_bindings.odin`,
   generated from the `@(lua=raycast, table=World, lua_zh="射线检测")` attribute.
2. The wrapper reads the arguments (`_lua_read_ffi_vec3` for the vectors, raising a Lua error on a wrong
   type) and calls `world_raycast_lua` in `lua_api_world.odin`.
3. That wrapper asks `lua_world()` for the world whose script is running, and calls the world-layer
   `physics_raycast(w, …)` (`world_physics.odin`).
4. The results are pushed back to Lua (`_lua_push_ffi_vec3` for the point and normal, an integer for the
   entity handle).

Nothing in Lua keeps state between frames; scripts keep it in entity fields (`Entity.set_number`
and friends write through `entity_writable_field`).

### A probe bake

1. The Probe Bake window (`ui_bake.odin`) or `blimpctl bake` calls `bake_probes(level)`
   (`editor_bake.odin`).
2. `bake_scene_bvh` collects every mesh of every `entity_bakes` entity as instances, and
   `scene_bvh_build` (`asset_bvh.odin`) builds a two-level BVH over the meshes' own BVHs.
3. The grid is sized from the settings (manual box, or the static geometry's bounds). Rays go out from
   every probe on a Fibonacci sphere, in parallel (`parallel_for`):
   - direct light at each hit (CPU copies of the shader's falloffs),
   - sky on escape,
   - previous-pass irradiance for bounces,
   - distances into the octahedral depth map.

   Each light group with lights gets its own SH layer.
4. `probe_grid_set` replaces the world's grid and builds the atlas picture. `probe_grid_save` writes the
   `.probes` sidecar, and `world_render_probes_recreate` (`render_probes.odin`) replaces the GPU copy.
5. Baking isn't an edit: no undo step, nothing unsaved.

### Hot reload

`app_hot_reload.odin` watches `assets/` and `assets_engine/` with `ReadDirectoryChangesW`, waits for
writes to settle, then by extension:

- glTF, bin, png → `app_reload_assets`: GPU idle, physics stopped, assets freed and loaded again, GPU
  asset buffers rebuilt, physics restarted. Entities keep their interned keys, so they pick up the new
  data.
- `.slang` → `render_shaders_reload`: every pipeline recompiled, all or nothing.
- audio → `sound_reload`. `.luacn` → transpiled to `.lua`. `.lua` → `lua_reload_script`: play worlds
  running it reload it, start included; `main.lua` reruns.

### Closing a world

A request (`world_request_close` from the UI or blimpctl) waits for the next frame's
`app_process_closes`:

1. Wait for the GPU.
2. Stop play first if it's playing or a play copy.
3. Close its views: `ui_forget_view` (window, panels, Editor_View), `render_view_destroy`, `view_free`.
4. Close the world: script, voices and physics stop, undo entries go, the UI and Editor_World forget it,
   `world_render_destroy` frees the GPU mirror, and `world_free` frees the world.

---

## 7. Subsystems

### Foundation (no prefix)

- **`app.odin`**: the `App` global (window, allocators, loggers, display scale), `app_init`,
  `app_run` and `app_shutdown`, self-relaunch for F9 and the schema editor's Apply
  (`app_rebuild_and_restart`), Show in Explorer, and `app_listener` (the camera the player hears through).
- **`basics.odin`**: vector and matrix aliases (the ones marked `@(lua_ffi)` cross into Lua as FFI
  cdata), the `Panic_On_Fail` allocator wrapper, sRGB curves, box helpers (`box_corners`,
  `box_transformed_bounds`, `BOX_EDGES`), `perpendicular`, reflection helpers for inline string buffers,
  and `parallel_for`.
- **`time.odin`**: frame-stable clocks: delta, seconds since start, frame index; plus a live clock for
  timeouts.
- **`serialize.odin`**: the one INI reader (`ini_next`, `Ini_Reader`) and the reflection codec between
  any struct and `key = value` lines (`serialize_struct`, `deserialize_value`, dotted paths through
  `struct_field_by_path`).
- **`entity.odin`**: entity handles, the predicates, `entity_default`, transforms, key interning, text
  round-trip (`entity_to_text`, `entity_apply_text`) and the guarded field writer
  (`entity_writable_field`).
- **`input.odin`**: per-frame keyboard, mouse and gamepad state, live only in game mode.
- **`loc.odin`**: every UI string, EN and ZH on one row; `tr(.Key)`.
- **`log_history.odin`**: the last 256 log lines in memory, beside the console: the on-screen error
  overlay and `blimpctl log` read it.
- **`search.odin`** (+ `gen_pinyin.*`): `search_matches`, case-insensitive substring match that also
  matches Chinese by pinyin (full syllables or initials).
- **`game_settings.odin`**: `game.ini`, settings that belong to the game rather than a world (the start
  level).

### Assets (`asset_`)

`asset_system.odin` loads every glTF under `assets/` and `assets_engine/` at init:

- meshes into three flat arrays (indices, positions, attributes);
- materials;
- images, shared across kits by path or content hash;
- models, kits and their node layouts;
- a mesh BVH per mesh (`asset_bvh.odin`, used by picking and the baker);
- Box3D collision cooked from `<model>_col` meshes;
- the average albedo the baker bounces.

Import converts glTF's right-handed space (reflect −X, swap winding). Keys are interned in their own
arena (`asset_keys`). `asset_system_reload` frees and reloads everything; the app rebuilds what depends
on it.

### Worlds (`world_`)

- **`world.odin`**: the `World` struct, `World_Settings` (background, exposure, shading, script, light
  groups, bake and retro settings), `world_add` (the one way in), unique names, `world_find`,
  `world_remove`, `entity_shading`, `entity_world_corners`.
- **`world_registry.odin`**: the `worlds` and `views` lists, the active view, opening scenes and kits
  (world part), close requests, freeing.
- **`world_play.odin`**: the play copy and its discard, `world_level`, the game camera, pause, step and
  the per-frame tick.
- **`world_scene.odin`**: `.level` save and load, and loading `[entity]` text (also the clipboard).
  `assets_engine/templates.level` is the starting lights and cameras: open it and copy from it.
- **`world_physics.odin`** (Box3D): queries only. Play builds a static or kinematic body per enabled
  entity with collision. Kinematic bodies follow their entities. Raycasts and the character mover back
  `World.raycast` and `Entity.move_character`.
- **`world_sound.odin`** (miniaudio): clips decoded at startup, a pool of 32 voices with stealing and
  coalescing, voices attached to entities, paused with their world.
- **`world_light_groups.odin`**: four switchable light groups with Quake-style flicker patterns and
  runtime overrides; `light_group_scales(w)` is what render, probes and the UI read.
- **`world_probes.odin`**: the baked probe grid: L2 SH layers, octahedral depth maps, the CPU sampling
  and visibility maths (mirroring `shading.slang`), the `.probes` sidecar, and the atlas image.

### Rendering (`render_`)

- **`render_dx.odin`**: the `Renderer_DX` global (device, queues, heaps, command lists, fences, scene
  pipelines), `Frame_Constants`, the three-call frame, shader hot reload, waiting for idle.
- **`render_buffers.odin`**: `Asset_Buffers` (shared static GPU data) and `World_Render` (each world's
  per-flight mirror), `buffers_build_scene`, uploads and barriers, the GPU light struct.
- **`render_view.odin`**: `Render_View`, render modes and lighting debug views, frame constants, the scene
  pass, retro settings.
- **`render_camera.odin`**: the free orbit camera's maths (eye, view, projection, ray) and camera-entity
  matrices.
- **`render_shadows.odin`**: the shadow map array per world, slice assignment, light cameras, the shadow
  pass with its static cache.
- **`render_post.odin`**: the post pipelines and passes.
- **`render_probes.odin`**: the GPU copy of a world's probes.
- **`render_debug_draw.odin`**: the debug line list and shapes, uploaded once and drawn per view range.
- **`render_gpu_timer.odin`**: per-pass GPU timestamps (the F3 overlay, `blimpctl timings`).

Shaders (`assets_engine/shaders/`, Slang compiled at runtime):

| Shader | Role |
|---|---|
| `scene.slang` | the scene vertex and pixel shaders: bindless fetch, vertex snap, Gouraud per-vertex light, affine UVs, cutout |
| `shading.slang` | all lighting: falloffs, spot/cylinder cones, hard shadow lookup, probe irradiance with visibility, the shading models |
| `shadow.slang` | depth-only shadow vertex shader |
| `post.slang` | fog (distance, height, probe-lit, lamp halos), tonemap, quantize/dither, bloom, point or CRT upscale |
| `debug_line.slang` | debug lines, depth-tested by hand against the scene depth |
| `common.slang`, `utils.slang` | shared constants and bindless helpers |

### Scripting (`lua_`)

- **`lua.odin`**: the Lua state, `setup.lua`, binding registration, `main.lua` and its engine hooks
  (`引擎.开始/更新/完结` = `Blimp.start/update/finish`), script hot reload.
- **`lua_world_script.odin`**: per-world scripts, each in its own environment, run only in play worlds;
  `lua_world()` (the running world).
- **`lua_api_world.odin`, `lua_api_entity.odin`, `lua_api_input.odin`**: the whole script API as
  `@(lua)` procs, thin wrappers over world procs. `World.debug_line` draws a line in the world's views
  until its next tick.
- **LuaCN**: Lua with 21 Chinese keywords (`如果`=if, `那么`=then, `本地`=local, …). `.luacn` files are
  transpiled to `.lua` at build time (`src/common/luacn.odin`) and on hot reload. `setup.lua` and
  `stdlib_aliases.lua` give every API table and the standard library Chinese names
  (`世界`=World, `实体`=Entity, `输入`=Input). `docs/lua.md` is the scripter's guide.

### Editor (`editor_`)

- **`editor_world.odin`**, **`editor_view.odin`**: the editor's per-world and per-view state.
- **`editor_selection.odin`**: selection ops (replace/add/remove/toggle), clicks, marquee, `view_pick`,
  `view_paste_point`, `selection_paste`, duplicate, delete, selection colours.
- **`editor_undo.odin`**: whole-world snapshots, one history across worlds, unsaved state ids.
- **`editor_gizmo.odin`**: move, rotate and scale with global/local space, pivot modes and snapping.
- **`editor_camera.odin`**: framing (F), orbit and zoom, mouse and keyboard navigation.
- **`editor_overlay.odin`**: world-space shapes drawn with ImGui on one view (`world_to_screen`, cone,
  cube, icon).
- **`editor_icons.odin`**: icon font codepoints, entity icons, and the viewport icon logic (size by
  constant screen size, picking).
- **`editor_shapes.odin`**: camera frustums, light reach and probe spokes as debug lines.
- **`editor_bake.odin`**: the CPU probe baker.
- **`editor_schema.odin`**: the schema editor's document: load, validate, save.

### UI (`ui_`)

`ui.odin` owns the ImGui frame: fonts, the main menu, the dock layout, the order panels draw in, and
the shared helpers (`Settings_Window`, `ui_font_size`, `ui_label_column`, `ui_retarget_world`,
`ui_forget_world`). Every other `ui_` file is one window or one part of one:

- viewports and their toolbars: `ui_view`, `ui_view_toolbar`;
- entity panels: `ui_entity_panels` (list and inspector), `ui_param_inspector` (the reflection
  inspector), `ui_context_menu` (copy, paste, duplicate, delete, hide);
- browsers: `ui_worlds`, `ui_resources` (GPU memory treemap);
- settings windows: `ui_world_settings`, `ui_retro`, `ui_bake`, `ui_game_settings`;
- `ui_schema_editor`;
- game mode: `ui_game`;
- small pieces: `ui_shortcuts`, `ui_unsaved` (save prompt), `ui_saved_state` (layout, language, open
  windows), `ui_stats` (F3 stats and the recent-errors overlay), `ui_theme`.

### App drivers (`app_`)

- **`app_lifecycle.odin`**: open, play, stop, close, reload: the cross-layer sequences.
- **`app_remote.odin`**: the blimpctl server on `127.0.0.1:47800` (debug builds). One text command per
  connection, run between frames (`blimpctl log` for recent log lines). Use `blimpctl help` for the list.
- **`app_hot_reload.odin`**: directory watchers and per-extension reload.
- **`app_renderdoc.odin`**: in-app RenderDoc captures (`--renderdoc`).

---

## 8. Code generation and the build

`odin run build.odin -file` does, in order:

1. Builds and runs `src/codegen` (`bin/codegen.exe`):
   - `codegen_entity.odin`: `entity_schema.ini` → `src/gen_entity.odin`;
   - `codegen_lua_binding.odin`: scans `src/` for `@(lua …)` procs and structs, `@(lua_ffi)` math types
     and `@(lua_int)` handles → `src/gen_lua_bindings.odin`. Output is sorted, so it only changes when its
     input does. One push and one read classifier marshal every type the same way;
   - LuaCN: every `.luacn` under `assets/` and `assets_engine/` → `.lua`.
2. Builds the engine, debug: `bin/blimp.exe`.
3. Builds `bin/blimpctl.exe`.

`odin run build.odin -file -- game` builds a release `out/game/game.exe` (no editor; plays the start
level) and copies the DLLs and assets beside it, without DCC sources or `.luacn`.

The pinyin table (`gen_pinyin.*`) is generated by hand with `tools/pinyin/gen_pinyin.py`.
`tools/vscode-luacn` is a VS Code extension for `.luacn` (syntax and LuaLS support).

Fastest check: `odin check src -debug -vet -collection:lib=E:/Libraries/odin_lib -custom-attribute:lua,lua_zh,table,method,lua_ffi,as,lua_int`.

---

## 9. File map

| File | Purpose |
|---|---|
| **Foundation** | |
| `app.odin` | App global, init / frame loop / shutdown, relaunch, Show in Explorer, sound listener choice |
| `basics.odin` | Math aliases, allocator wrapper, sRGB, box helpers, `parallel_for` |
| `time.odin` | Frame-stable clocks |
| `serialize.odin` | INI reader and the reflection struct codec |
| `entity.odin` | Entity handles, predicates, defaults, text round-trip, guarded field writes |
| `input.odin` | Keyboard, mouse, gamepad per frame |
| `loc.odin` | EN/ZH string table, `tr` |
| `log_history.odin` | Recent log lines in memory |
| `search.odin` | Search with pinyin matching |
| `game_settings.odin` | `game.ini` |
| `gen_entity.odin` | *Generated*: `Entity`, enums, defaults, labels |
| `gen_lua_bindings.odin` | *Generated*: Lua wrappers and registration |
| `gen_pinyin.odin` | *Generated*: pinyin syllables (+ `gen_pinyin.bin`) |
| **Assets** | |
| `asset_system.odin` | glTF import, meshes, materials, images, kits, collision, key interning, reload |
| `asset_bvh.odin` | Mesh BVH and Scene BVH builder and queries |
| **Worlds** | |
| `world.odin` | `World`, settings, `world_add`, names, find/remove |
| `world_registry.odin` | World and view lists, active view, open/close (world part) |
| `world_play.odin` | Play copy, game camera, pause/step/tick |
| `world_scene.odin` | `.level` save/load, `[entity]` text loading |
| `world_physics.odin` | Box3D bodies, raycast, character mover |
| `world_sound.odin` | Clips, voices, listener |
| `world_light_groups.odin` | Light groups, flicker, overrides |
| `world_probes.odin` | Probe grid, SH/visibility maths, `.probes` file, atlas |
| **Rendering** | |
| `render_dx.odin` | Renderer global, frame constants, the frame, shader reload |
| `render_buffers.odin` | Asset buffers, world mirrors, scene build, uploads |
| `render_view.odin` | Views, render modes, frame constants, scene pass |
| `render_camera.odin` | Camera maths |
| `render_shadows.odin` | Shadow maps, pass and cache |
| `render_post.odin` | Post passes |
| `render_probes.odin` | GPU probe buffers |
| `render_debug_draw.odin` | Debug lines |
| `render_gpu_timer.odin` | GPU timestamps |
| **Scripting** | |
| `lua.odin` | Lua state, engine hooks, script reload |
| `lua_world_script.odin` | Per-world scripts, `lua_world` |
| `lua_api_world.odin` | `World` / `世界` script API |
| `lua_api_entity.odin` | `Entity` / `实体` script API |
| `lua_api_input.odin` | `Input` / `输入` script API |
| **Editor** | |
| `editor_world.odin` | Per-world editor state, unsaved tracking, save |
| `editor_view.odin` | Per-view editor state |
| `editor_selection.odin` | Selection, picking, paste, delete |
| `editor_undo.odin` | Undo/redo snapshots |
| `editor_gizmo.odin` | Transform gizmo |
| `editor_camera.odin` | Framing and navigation |
| `editor_overlay.odin` | ImGui shapes in world space |
| `editor_icons.odin` | Icon font, entity icons, viewport icons |
| `editor_shapes.odin` | Camera/light/probe debug shapes |
| `editor_bake.odin` | Probe baker |
| `editor_schema.odin` | Schema document model |
| **UI** | |
| `ui.odin` | ImGui frame, menus, layout, shared UI helpers, retarget/forget hooks |
| `ui_view.odin` | World windows, viewports, marquee, editor debug lines |
| `ui_view_toolbar.odin` | Viewport toolbar, tool column, lighting menu |
| `ui_entity_panels.odin` | Entity list and inspector panels |
| `ui_param_inspector.odin` | Reflection inspector widgets |
| `ui_context_menu.odin` | Entity actions and the right-click menu |
| `ui_worlds.odin` | Worlds browser |
| `ui_resources.odin` | GPU resources treemap |
| `ui_world_settings.odin` | World Settings window |
| `ui_retro.odin` | Retro Look window |
| `ui_bake.odin` | Probe Bake window, atlas, bake box |
| `ui_game_settings.odin` | Game Settings window |
| `ui_schema_editor.odin` | Schema editor window |
| `ui_game.odin` | Game mode, start level |
| `ui_shortcuts.odin` | Editor keyboard shortcuts |
| `ui_unsaved.odin` | Save / Don't Save / Cancel prompt |
| `ui_saved_state.odin` | Layout, language and open windows in imgui.ini |
| `ui_stats.odin` | F3 stats and recent-errors overlay |
| `ui_theme.odin` | ImGui theme |
| **App drivers** | |
| `app_lifecycle.odin` | Open, play, stop, close, asset reload |
| `app_remote.odin` | blimpctl server |
| `app_hot_reload.odin` | File watchers and reload dispatch |
| `app_renderdoc.odin` | RenderDoc integration |
| **Codegen** (`src/codegen/`) | |
| `codegen_common.odin` | Codegen entry point |
| `codegen_entity.odin` | Schema → `gen_entity.odin` |
| `codegen_lua_binding.odin` | `@(lua)` scan → `gen_lua_bindings.odin` |

---

## 10. How to…

**Add an entity field.** Add it in the Schema Editor window (or in `entity_schema.ini`: a `[field.x]`
section with `type`, `en`, `zh`, `default`, optional `tags`, `section`, `note`), then Apply / rebuild.
It's saved, copied, inspected and scriptable (`Entity.get_number(e, "x")`) with no further code. Read it
wherever a system needs it.

**Add a Lua function.** Write a world-layer proc that takes `^World`, then a thin wrapper in the right
`lua_api_*.odin`:

```odin
@(lua=my_thing, table=World, lua_zh="我的东西")
world_my_thing_lua :: proc(x: f32) -> bool {
    w := lua_world() or_else nil
    return w != nil && world_my_thing(w, x)
}
```

Rebuild; codegen writes the binding. Add the Chinese alias to the LuaLS definitions and document it in
`docs/lua.md`.

**Add a UI string.** Add a `Loc_ID` member and its `{ .EN = "…", .ZH = "…" }` row in `loc.odin`, then use
`tr(.Your_Key)`. Window titles end in `###id`.

**Add a settings window for a world.** Keep a `Settings_Window`, draw with
`settings_window_toggle/open_for`, call `settings_window_track_edit(&win, before)` after the widgets,
and hook its retarget/forget into `ui_retarget_world` / `ui_forget_world`.

**Add a render pass.** Record it in `renderer_dx_draw_frame` (`render_dx.odin`) with a
`gpu_timer_begin/end` scope, give its pipeline to `renderer_dx_pipelines` so shader hot reload rebuilds
it, and put any new constants in `Frame_Constants`, keeping the Odin and Slang layouts in step (the
asserts check offsets).

**Add something that happens on open/play/stop/close.** Add the call to the matching proc in
`app_lifecycle.odin`, in order. Don't call upward from world or render code.
