# Blimp

Custom game engine. Odin, DX12, GPU-driven bindless pipeline. Solo project, partly for
learning. Target art style is PS1-era "without the hardware limitations."

## Working agreement

- Decisions in this file and in `docs/` are settled. Don't relitigate them or propose the
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
| `docs/editor.md` | editor UI, worlds, selection, clipboard, undo, play mode, function keys, icons and viewport drawing, remote commands, RenderDoc |
| `docs/gameplay.md` | entities (camera/light fields), state rules, Lua boundary, sound, physics (Box3D) |
| `docs/rendering.md` | buffers, indirect draws, skinning, particles, alignment, lighting/baker/shadows, PS1 post chain |
| `docs/assets.md` | glTF import, kits, asset keys, texture sharing |
| `docs/animation.md` | animation tree, events, procedural layer |
| `docs/memory.md` | arenas and allocators in detail |
| `docs/localization.md` | the loc table in detail |

When a decision changes, update the doc that owns it. Only rules that apply everywhere live here.

## Language and style

- Odin. Snake_case procs, Pascal_Snake_Case types (`Mesh_Instance`, `Draw_Command`).
- `src/` is one package; files are grouped by prefix: `asset_`, `render_`, `world_`, `editor_`
  (editor logic), `ui_` (ImGui panels), `lua_`, `gen_` (generated). Unprefixed files are the
  shared foundation (`app`, `basics`, `loc`, `time`, `serialize`).
- Fat structs and top-down per-system loops. No ECS, no components, no OOP hierarchies.
- Multiple linear passes over flat arrays per frame is correct and intentional.
- Explicit allocator parameters on anything that returns allocated memory. Procs that
  only need working space use scratch internally.

## Core rules

- **Memory:** group arenas by lifetime first — permanent (assets, never reset), level (entities,
  level unload), frame (frame start), scratch (`context.temp_allocator`). Prefer `core:mem/virtual`
  `Arena`. Dynamic arrays in arenas strand memory on grow: reserve up front.
- **Assets** load at init and never change at runtime: no streaming, manifests or meta files. A glTF
  file is a kit. Keys are project-relative forward-slash paths plus a name
  (`assets/models/car.gltf:body`), never absolute, no UUIDs.
- **Coordinates:** left-handed, Y-up, +Z forward, clockwise front faces. glTF import reflects `-X`
  **and** swaps winding; both are required, don't remove the swap. Reversed-Z (`GREATER`, clear 0).
  Float HDR target. Simple forward, not clustered.
- **Naming:** Entity places a Model (CPU list of meshes) → Mesh (one glTF primitive) → Mesh_Instance
  (entity-mesh pair) → draw command. Visible means `entity_drawn`.
- **GPU structs** pad to 16-byte multiples with named fields and assert `size_of` matches HLSL.
- **Entities** are one fat struct. Cameras and lights are flat fields (`camera_type`, `light_type`,
  `color`, `fov`, `size`, `range`…), no nesting; two roles are two entities. Fields come from
  `entity_schema.ini`, which generates `src/gen_entity.odin` (don't hand-edit the generated file).
- **Worlds** are instantiable; systems take `^World`. Editor state stays off core structs
  (`Editor_View` and other editor-side structs, not `Render_View`, `Camera` or the renderer).
- **Every edit calls `undo_push(w)` first**: undo and unsaved tracking both come from it. Data an
  entity points into is replaced, never mutated in place.
- **Play mode runs a copy** of the level; `world_level(w)` is the world that's edited and saved. Game
  systems check `w.ticks`, never `paused`.
- **Viewport drawing at a 3D position** uses `debug_*` (depth-tested scene lines) or `ui_overlay_*`
  (ImGui on top of one view), not ad hoc ImGui calls.
- **Lua issues commands and queries state; it never holds state.**
- **UI text** goes through `tr(.Key)` with EN and ZH on one row in `loc.odin` (default zh). Logs,
  asserts, keys and paths stay ASCII English. Window titles end in a `###id` suffix.

## Build, check, verify

- Build: `odin run build.odin -file` (there is no build.exe). Close a running engine first, since
  Windows locks `bin/blimp.exe`.
- Type-check only (faster): `odin check src -debug -vet -collection:lib=E:/Libraries/odin_lib -custom-attribute:lua,lua_zh,table,method,lua_ffi,as,lua_int`
- A debug build serves `bin/blimpctl.exe` on `127.0.0.1:47800` (`blimpctl help`). Commands and the
  RenderDoc workflow are in `docs/editor.md`.
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
3. Shader hot reload, and asset hot reload via timestamp polling (~100 lines, no meta files).
4. Simplest animation: one clip, one time, one pose. Blending after.
5. PS1 post chain — small, and the fun visible one.
6. Debug-only fence assertion layer for buffer/GPU write hazards.
