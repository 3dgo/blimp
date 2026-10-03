# Blimp

Custom game engine. Odin, DX12, GPU-driven bindless pipeline. Solo project, partly for
learning. Target art style is PS1-era "without the hardware limitations."

## Working agreement

- Decisions in this file and in `claude/` are settled. Don't relitigate them or propose the
  "standard" alternative unless something concrete has changed.
- Prefer the simplest thing that solves the actual problem. Speculative generality is a
  bug. If a system isn't needed yet, don't build scaffolding for it.
- Precomputed and baked over realtime and screen-space — true for both the art style and
  the scope.
- No hidden abstraction over lifetime, allocation, or cost. Tedious and visible beats
  clever and implicit.

## Design docs — read the one for the area you're touching

| File | Read when working on |
|---|---|
| `claude/editor.md` | editor UI, worlds, selection, clipboard, undo, play mode, function keys, icons and viewport drawing, remote commands, RenderDoc |
| `claude/gameplay.md` | entities (camera/light fields), state rules, Lua boundary, sound, physics (Box3D) |
| `claude/rendering.md` | buffers, indirect draws, skinning, particles, alignment, lighting/baker/shadows, PS1 post chain |
| `claude/assets.md` | glTF import, kits, asset keys, texture sharing |
| `claude/animation.md` | animation tree, events, procedural layer |
| `claude/memory.md` | arenas and allocators in detail |
| `claude/localization.md` | the loc table in detail |
| `docs/lua.md` | the Lua/LuaCN scripting API as game scripters see it (Chinese guide, castle walkthrough); update it when an `@(lua)` proc changes |

When a decision changes, update the doc that owns it. Only rules that apply everywhere live here.
`claude/` holds these design docs (written for Claude); `docs/` is for human readers only — don't put
design notes there.

## Language and style

- Odin. Snake_case procs, Pascal_Snake_Case types (`Mesh_Instance`, `Draw_Command`).
- `src/` is one package; files are grouped by prefix: `asset_`, `world_`, `render_`, `lua_`, `editor_`
  (editor logic), `ui_` (ImGui panels), `app_` (drivers: lifecycle, remote control, hot reload,
  RenderDoc), `gen_` (generated). Unprefixed files are the shared foundation (`app`, `basics`, `time`,
  `serialize`, `entity`, `input`, `loc`, `search`, `game_settings`).
- **Layers call downward only:** foundation → asset → world → render → lua → editor → ui → app. The
  renderer reads worlds and never writes them; world code never calls render, Lua, editor or UI.
  Sequences that touch every layer (open, play, stop, close, asset reload) are one proc each in
  `app_lifecycle.odin`, which ui and blimpctl call; `app_run` is the frame order. Pass data down
  (`input_update(game_mode)`, `sound_update(listener)`) rather than reaching up for it.
- Fat structs and top-down per-system loops. No ECS, no components, no OOP hierarchies.
- Multiple linear passes over flat arrays per frame is correct and intentional.
- Explicit allocator parameters on anything that returns allocated memory. Procs that
  only need working space use scratch internally.

## Core rules

- **Memory:** group arenas by lifetime first — permanent (assets, never reset), level (a world and its
  probe arena, freed when it closes), frame (frame start), scratch (`context.temp_allocator`). Prefer `core:mem/virtual`
  `Arena`. Dynamic arrays in arenas strand memory on grow: reserve up front.
- **Assets** load at init and never change at runtime: no streaming, manifests or meta files. Debug
  hot reload rebuilds all of them, as init would (`app_hot_reload.odin`). A glTF file is a kit. Keys are
  project-relative forward-slash paths plus a name (`assets/models/car.gltf:body`), never absolute, no UUIDs.
  Anything that keeps a key interns it (`asset_intern`), so it outlives a reload. Strings decoded from
  text are temp; an entity enters a world only through `world_add`, which interns its keys.
- **Coordinates:** left-handed, Y-up, +Z forward, clockwise front faces. glTF import reflects `-X`
  **and** swaps winding; both are required, don't remove the swap. Reversed-Z (`GREATER`, clear 0).
  Float HDR target. Simple forward, not clustered.
- **Naming:** Entity places a Model (CPU list of meshes) → Mesh (one glTF primitive) → Mesh_Instance
  (entity-mesh pair) → draw command. Visible means `entity_drawn`.
- **GPU structs** pad to 16-byte multiples with named fields and assert `size_of` matches HLSL.
- **Entities** are one fat struct. Cameras and lights are flat fields (`camera_type`, `light_type`,
  `color`, `fov`, `size`, `range`…), no nesting; two roles are two entities. Fields come from
  `entity_schema.ini`, which generates `src/gen_entity.odin` (don't hand-edit the generated file).
- **Worlds** are instantiable; systems take `^World`. Editor state stays off core structs: it lives in
  `Editor_World` (active entity, Shift anchor, unsaved tracking) and `Editor_View`, not in `World`,
  `Render_View`, `Camera` or the renderer. The one exception is `Entity.selected`, so undo carries it.
- **Every edit calls `undo_push(w)` first**: undo and unsaved tracking both come from it. Data an
  entity points into is replaced, never mutated in place.
- **Play mode runs a copy** of the level; `world_level(w)` is the world that's edited and saved. Game
  systems check `w.ticks`, never `paused`.
- **Viewport drawing at a 3D position** uses `debug_*` (depth-tested scene lines) or `overlay_*`
  (ImGui on top of one view), not ad hoc ImGui calls.
- **Lua issues commands and queries state; it never holds state.** The whole script API is the
  `@(lua)` procs in `lua_api_*.odin`, thin wrappers over world procs; they act on the world whose
  script is running (`lua_world()`).
- **UI text** goes through `tr(.Key)` with EN and ZH on one row in `loc.odin` (default zh). Logs,
  asserts, keys and paths stay ASCII English. Window titles end in a `###id` suffix. Every search box
  matches through `search_matches` (`search.odin`), so Chinese is also found by pinyin.

## Build, check, verify

- Build: `odin run build.odin -file` (there is no build.exe). Close a running engine first, since
  Windows locks `bin/blimp.exe`.
- Game: `odin run build.odin -file -- game` → `out/game/game.exe` (release: no editor, plays
  `game.ini`'s start level) with the DLLs and assets beside it.
- Type-check only (faster): `odin check src -debug -vet -collection:lib=E:/Libraries/odin_lib -custom-attribute:lua,lua_zh,table,method,lua_ffi,as,lua_int`
- A debug build serves `bin/blimpctl.exe` on `127.0.0.1:47800` (`blimpctl help`). Commands and the
  RenderDoc workflow are in `claude/editor.md`.
- **Verify with the cheapest check that proves the change**, in this order:
  1. type-check / build clean;
  2. blimpctl text replies (`get`, `pick`, `entities`, `views`, `timings`, `resources`);
  3. one screenshot or capture plus at most one crop, only for what only a picture can show.

  For purely visual UI tweaks (layout, colours, hover), build and let the user look.
- **Keep context small:** grep and read line ranges rather than whole files; pipe build and log
  output through `tail`/`grep`.

## Build order

1. **GPU timestamps per pass, and a debug line renderer.** Everything is easier once you can
   see. Do these first.
2. **Reversed-Z**, before any shader assumes otherwise.
3. ~~Shader hot reload, and asset hot reload~~ — done (directory watcher, no meta files).
4. Simplest animation: one clip, one time, one pose. Blending after.
5. PS1 post chain — small, and the fun visible one.
6. Debug-only fence assertion layer for buffer/GPU write hazards.
