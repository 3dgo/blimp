# Editor: worlds, editing, play mode, remote control

### Worlds & editing

- **`World` is an instantiable struct**: `entities` handle map, level arena, `render: World_Render`,
  `active`, `title` and `save_path`. It is not globals, and systems take `^World`.
  - Any number of worlds can be open at once. They live in a pointer-stable registry,
    `worlds: [dynamic]^World` (`world_registry.odin`), where each world is individually allocated
    because views, panels and undo hold `^World`.
  - First launch opens the Worlds window with Templates docked above it. After that imgui.ini keeps the
    layout, the UI language and which project-wide windows are open (`ui_saved_state.odin`); world windows, views and entity
    panels belong to a world and aren't reopened. Worlds lists open worlds, scenes (`.level`
    files under `assets/` and `assets_engine/` only: the extension decides) and kits.
  - **Show in Explorer** (`app_show_in_explorer`, Explorer with the file selected) is how a level or kit
    gets edited outside the engine and resaved: right-click a row in Worlds, the folder button beside Save
    on a viewport toolbar, or right-click a block in GPU Resources.
  - Closing a world or view is deferred to `world_registry_process_pending`, after
    `renderer_dx_wait_idle`.
- **A kit is just a world built from a glTF.** There is no kit or preview world type.
  - A scene world is built from a `.level` (`world_open_scene`), a kit world from a glTF
    (`world_open_kit`, one entity per `Kit_Node`). That constructor is the only difference.
  - `save_path == ""` marks a kit, which can't be saved back to its glTF.
  - There is no read-only mode. The inspector shows a "won't be saved" warning instead.
- **A world owns its GPU draw mirror; a view is cheap.**
  - `World_Render` holds the world's per-flight transform, mesh-instance and draw-command buffers.
    It is built once per world per frame.
  - `Render_View` is `{target, camera, world, frame_constants}`. You can open many per world:
    several viewports on one scene are several views sharing one `world` pointer.
  - **Editor state stays off core structs.** A view's editor side is an `Editor_View`
    (`editor_view.odin`): screen rect, hover, camera navigation, gizmo, marquee and window placement.
    The UI keeps one per view (`editor_view(v)`, freed with the view).
    - `render_camera.odin` is only what rendering and picking need from a view's free `Camera` (eye, view,
      projection, ray; camera entities' matrices). Everything the editor does to it is `editor_camera.odin`:
      placing (a new view's angle and framing, F), the orbit/zoom moves, and navigation (mouse and keyboard →
      moves; the gesture in progress is `Editor_View.nav.drag`, a `Nav_Drag`). `editor_view.odin` is just the
      per-view editor state and its lifetime.
    - New editor features add state there, or to other editor-side structs, not to `Render_View`,
      `Camera` or the renderer.
  - **Drawing in a viewport at a 3D position comes in two layers.** Use these rather than ad hoc ImGui calls.
    - `debug_*` (`render_debug_draw.odin`): lines in the scene pass, depth-tested so geometry hides them, 1px.
      It has line, box, axes, circle, sphere, cone, arrow and frustum. Use it for things that live in the
      world, like a light's reach.
    - `overlay_*` (`editor_overlay.odin`): world-space shapes drawn with ImGui on top of one view, crisp and any
      thickness. Lines are clipped at the near plane. It has line, polyline, circle, box, arrow, disc, a
      shaded cone and cube, text, and icon (a font-glyph sprite). Use it for tools and markers, such as
      the gizmo and the camera/light icons.
      - Use it inside the view's window: `o := overlay_begin(ev); defer overlay_end(o)`.
      - `world_to_screen` lives there too.
  - Shared static asset GPU data lives in `Asset_Buffers` / `asset_buffers`.
  - Picking and each view's debug-line range are per view. Selection is per world (next bullet).
- **Selection** (`editor_selection.odin`): membership is the entity's `selected` field (`hidden, noserialize`).
  - That way undo snapshots carry it, delete and paste need no bookkeeping, and it never reaches
    files or the clipboard. Selection changes don't call `undo_push`, so they don't dirty the world.
  - `World.active` is the selected entity the inspector shows and the gizmo pivots on.
- **Inspector** (`ui_param_struct` over `Entity`, `ui_entity_inspector_body`): a presentation of the flat
  entity, not a structure in it. Every field stays shared and always shown; nothing hides by kind.
  - Sections: a field's schema `section` (a member of `enum.EntitySection`, emitted as a `section:` tag)
    puts it under that collapsing header. Fields without one come first, then sections in the enum's order.
    The schema editor picks it per field and can add sections (that builtin enum's members stay editable).
  - Search (per panel, `search_matches`) matches a field's id, its label in any language or its text value
    (strings, an enum's choice, set flags; not numbers), or a section's name (which shows all its fields). While searching, sections are separators, not folds. The entity list
    has the same box over entity names.
  - A field that differs from its schema default (`entity_apply_defaults`) has a bold label (`ui.font_bold`),
    colour unchanged; right-clicking a label offers Reset to Default.
  - Multi-edit: with several selected, the inspector shows the active entity. A field where the others differ
    has an amber label (numbers show a dash). An edit applies to all of them, but only what changed
    (`param_apply_changes`): one vector component, the toggled flags, otherwise the whole field. `identity`
    fields (the name) are skipped. Same undo step.
  - Viewport: click or a crossing marquee replaces the selection; Shift adds, Ctrl+Shift removes,
    Ctrl toggles (`Selection_Op`). Alt stays orbit.
    A plain double-click on an entity, in a viewport or the entity list, frames it like F (from the list: in
    the active view if it shows that world, else its first view — `editor_view_for_world`).
    Ctrl+D duplicates the selection in place and selects the copies (Unity). Ctrl+A selects all.
  - **Right-click menu** (`ui_context_menu.odin`): in a viewport, an RMB release without flying (under
    `NAV_CLICK_PX` of travel, no WASD) is a click. It and the entity list open one menu: copy, paste at
    the click, Paste Over, duplicate, delete, select all / deselect, frame, hide / unhide all.
    - Right-clicking an unselected entity selects it first, so the menu acts on it.
    - The shortcuts call the same action procs, so the two can't drift.
    Entity list: Shift+click selects a range from `select_anchor`, Ctrl+Shift adds the range.
  - Operations act on the whole selection: gizmo, copy, delete, Paste Over, F.
  - Gizmo: the same change applies to every member. Pivot mode (the tool column left of the viewport): **Selection Center**
    (default) rotates/scales the group about its combined bounds centre; **Individual Pivots** turns
    each about its own pivot.
  - Pasting several blocks keeps their layout, centred on the paste point; pasting one ignores its
    transform (as before).
- **World window.** Opening a world creates a `World_Host`: one floating window (centred, cascaded,
  960×540, 320×180 minimum) titled "`<file>` 视口". It holds its own DockSpace laid out as
  [ viewport | entity list / inspector ], with the tab bar auto-hidden.
  - The session's first world window docks into the main window's central node instead of floating.
  - Every window dragged outside the main window becomes an OS window parented to it
    (`ConfigViewportsNoDefaultParent = false`), so the main window never covers it.
  - Its panels start pinned to that world. They keep the Follow/pin combo, so they can be retargeted.
  - `Entity_Panel.owner` means only that the panel is docked in that window and closes with it.
  - "New Viewport" adds a plain extra view window onto an open world.
  - Panel targeting is explicit: follow the active world, or pin to one. Docking never links a panel.
- **`active_view`** is the viewport you last focused, or the world you last clicked in a panel
  (`world_activate`). It may be nil. Its world is the target of Ctrl+C/V. Undo entries carry their
  own world.
- **Lua has two tiers** (`lua_world_script.odin`).
  - Engine hooks (`引擎.开始/更新/完结`) run for the whole session.
  - World scripts belong to a world and run only while it's open. The script is the world's
    `[world] script` path; it defines `世界.开始()`/`World.start()` and `世界.更新(时间差)`/`World.update(dt)`,
    like the engine's `引擎.开始`.
  - Each world script runs in its own environment (falls back to `_G`), so open worlds can't clobber
    each other. Its `世界`/`World` is its own table falling back to the shared bindings, so the hooks
    never land in the shared table.
  - `@(lua)` world/entity procs take no `^World`, since a world pointer can't be marshalled. They act
    on `lua_world()`: the world whose script is running, else `game_world`. That world is unrendered,
    isn't in `worlds`, and is what engine hooks act on.
  - World scripts run only in play worlds (next bullet). Init runs at Play, or when the script path
    changes. A script error logs once and stops that world's script.
  - `World.time()` / `世界.时间()` is the play world's game clock (`World.time`, seconds since Play), advanced by
    `world_play_tick` only on frames that tick, so pause and F10 step hold it. Scripts animate from it rather
    than keep a clock of their own.
- **Play mode runs a copy** (`world_play.odin`). Play builds a play world from the level (same entities
  and settings), and every view of the level switches to it. Stop switches them back and closes the copy.
  - The level is never touched while playing, so nothing from play can leak into it. This was chosen over
    snapshot-and-restore because forgetting to reset something would silently corrupt the level, whereas
    a copy fails loudly.
  - Links: `level.play_world` points to the copy, and `play.play_source` points back to the level.
    `world_level(w)` is the world that's saved and edited.
  - Nothing is saved from play. A play world has no save_path, and the toolbar Save is disabled while playing.
  - A play world keeps no undo: `undo_push` returns false there. A playing level's own steps wait
    until Stop.
  - Editor state pinned to a world follows the switch (`ui_retarget_world`), and drags in progress end.
    New editor state that pins a `^World` hooks in there, next to `ui_forget_world`.
  - Closing a play view, a playing level or a play world stops play first (`world_registry_process_pending`).
    The unsaved prompt asks about the level.
  - Runtime systems (physics, animation, audio) belong to the play world: built with it, freed when it closes.
  - Keys (and toolbar buttons): F5 Play, F6 Pause, F7 Stop, F10 step one frame while paused (game systems check `w.ticks`,
    set once per frame by `world_play_tick`, never `paused`). Esc stays the game's. No Restart: Stop is the reset.
  - **Game mode** (`ui_game.odin`): Play also makes that view the whole window as the game, rendered through
    the play world's first enabled camera entity (`Render_View.game_camera`; the editor camera if there's none).
    The editor isn't drawn at all, so no editor window, input or letter shortcut runs, and docking is untouched.
    F8 switches between game mode and the editor while the game keeps running; Stop leaves it. Only function
    keys work in game mode. A release build is always in it: it plays the start level at startup.
- **Game Settings** (`game_settings.odin`, `game.ini` at the project root, Show menu): settings that belong to
  the game, not one world. `start_level` opens at startup (and plays in release). Not undoable; written after each edit.
- **Editor function keys** (`ui_handle_shortcuts`): F2 renames the active entity in place in the entity list,
  F3 toggles the stats overlay (FPS, GPU time per pass, on the foreground draw list), F11 maximizes the
  hovered viewport over the main window (its host keeps running underneath, so docking survives), and F9
  relaunches the engine through the unsaved prompt, with the same launch options. F12 is left to
  RenderDoc's capture key.
    While playing, the viewport has a border (amber when paused) and the title shows ▶.
- **World settings** (`World_Settings`) are the scene file's `[world]` section, written before the
  entities: background colour, exposure, script path, the light groups' starting values (claude/rendering.md → Light groups),
  and the probe bake's settings (`bake.*`, hidden here: they're
  edited in the Probe Bake window, claude/rendering.md → Baker; baking isn't an edit — no undo, not unsaved).
  - Only fields something reads; adding one is one line (reflection inspector + serializer).
  - Edited in the World Settings window (gear button on the viewport toolbar). Undo and unsaved
    tracking cover them.
  - The code button beside the gear opens the script in VS Code (`CODE_EDITOR`, `cmd /c <cli> <project> -g <script>`):
    the project's window if one is open, else a new one on the project folder. A `.lua` built from a
    `.luacn` opens the `.luacn`.
- **Retro toggle** (grain icon on the viewport toolbar) flips that view's `Render_Mode` between the
  retro look and a clean full-res render (`claude/rendering.md` → Retro look). Per view, not saved,
  not undoable. Beside it, the tune icon opens the Retro Look window: the level's effect settings,
  saved and undoable like World Settings.
  - Pasted text never touches them: only `scene_load` reads `[world]`.
- **Lighting menu** (lightbulb on the viewport toolbar): that view's lighting debug view, probes on/off,
  indirect multiplier and the probe overlay, plus the world's light-group scales (runtime overrides like
  Lua's, shared by its views, never saved; "Back to saved" clears them) (claude/rendering.md → Baker). Per view, not saved, not undoable;
  the button lights while anything differs from plain Lit. **GPU Resources** (Show menu, `ui_resources.odin`):
  treemap of every GPU resource by owner — assets, each world, each view, engine. Click a group to show
  only it (Back / Backspace returns); texture tooltips show the picture (an ImGui-heap SRV per asset
  texture, `asset_buffers.texture_ui`).
- **The clipboard is the scene `[entity]` text format** (`entity_to_text` / `entity_apply_text` over
  the generic codec in `serialize.odin`).
  - One format backs save, duplicate, instantiate-from-kit and apply-settings. There is no drag
    and no bespoke asset-placement path.
  - It uses the OS clipboard (via ImGui), so blocks interchange with `.level` files in a text
    editor and work across worlds.
  - **Ctrl+C** copies the selected entity in the active world.
  - **Ctrl+V always creates new** entities and never overwrites. Placement comes from the paste
    point, not the block: the mouse raycast hit in the active view, or the viewport-centre ray when
    the mouse is outside it. If either ray misses, the entity lands 5 units in front of the camera.
  - **Paste Over** (one button at the top of the inspector) overrides the selected entity in place.
    It keeps the target's handle, skips `identity` and `placement` fields, snapshots for undo first,
    and is enabled only for a single-block clipboard. Everything else it touches is controlled by
    *what you copy*.
  - **Per-field paste**: the `widget:` picker has a Paste button beside it. It accepts a whole
    `[entity]` block (and takes that field's value) or a bare key such as
    `assets/models/car.gltf:police`.
- **Templates** (`ui_templates.odin`, Show menu) add a light, camera or other starting entity to the active
  world. They are the `[entity]` blocks of `assets_engine/entity_templates.ini`: the level format, but
  not a `.level`, so the Worlds window never lists it.
  - A click works like a one-block Ctrl+V at the viewport centre, but keeps the block's rotation and
    scale (a spot starts pointing down). Fields a block leaves out take their schema default.
  - **Icons**: an entity's `icon` field is a hex Material Symbols codepoint (`E835`), shown in the viewport
    (where it can be clicked), the entity list, the Templates window and beside the inspector field.
    Empty means a light or camera shows its type's icon (`entity_icon`) and anything else none.
  - Edit Templates opens the file as a world, so templates are authored with the editor's own tools.
    Save it and press Refresh.
- **Undo is whole-world snapshots** (`editor_undo.odin`): before any edit, copy the world's entity map.
  - The map is a fixed-size `Static_Handle_Map` value of plain-data entities, so a snapshot is one
    struct copy. Restoring it brings back exact handles, so no fix-up is needed for deletes or pastes.
  - New editor operations just call `undo_push(w)` first. Edits noticed after the fact (gizmo drag,
    inspector widgets) use `undo_push_edited` with the entity's pre-edit state.
  - There is one history across worlds: Ctrl+Z undoes, Ctrl+Shift+Z redoes.
  - Rule: data an entity points into (arena strings, later slices) is replaced, never mutated in
    place, because snapshots share it.
  - **Unsaved changes come from undo too.** `undo_push` gives the world a fresh `state_id`, and
    undo/redo restore it along with the snapshot.
    - The world is dirty when `state_id != saved_state_id`, so undoing back to the save is clean.
    - Dirty worlds show `*`, Save is disabled when clean, and closing a dirty world or quitting asks
      Save / Don't Save / Cancel (`ui_unsaved.odin`). Kits are never dirty.
    - An edit that bypasses `undo_push` would also bypass this. Every edit path must call it.
- **Entity names are unique per world.** `world_add`, scene load and paste go through
  `world_unique_name`, which yields `base_1`, `base_2` and so on. The inspector re-checks once no
  item is active, not per keystroke.
- Backtick tags drive the above alongside `noserialize`/`hidden`/`readonly`:
  - **`identity`**: kept on any override, e.g. `name`.
  - **`placement`**: the entity's placement and relationships in the scene. Today that's the
    transform; later it covers fields like a parent/attach. It is ignored by every paste.
  - Both are authored per field in the schema; extending them is a tag, not code.
- **Text fields: the type says who owns it.** `sbuf64` / `sbuf128` / `sbuf256` = text the entity owns,
  inline, sized by content (64: names, ids, gameplay tags · 128: labels · 256: paths, descriptions) —
  editable in the inspector by default (`readonly` disables). `string` = a
  reference to text owned elsewhere (an asset key in the asset arena) — never free-text edited; a
  **`widget:<kind>`** tag chooses how it's picked (`widget:model`, `widget:texture`: a dropdown over
  the loaded assets' keys, storing the interned key — no allocation), otherwise shown read-only.
  Prefer `sbuf64` unless the string already exists somewhere and the entity shouldn't own it.


## Remote control (tools / Claude)

A debug build listens on `127.0.0.1:47800` (`src/editor_remote.odin`). `bin/blimpctl.exe` (`tools/blimpctl`,
built by `build.odin`) sends one text command and prints the reply. `blimpctl help` lists the commands:
worlds, open/save/close, entities/get/set/paste/delete/select, play/stop/pause, game, undo/redo, views/camera/frame/pick/menu, tool,
timings (GPU time per pass, `render_gpu_timer.odin`), resources (every GPU resource by owner — assets, worlds,
views, engine — the data behind the GPU Resources treemap window, `ui_resources.odin`), bake / probe (claude/rendering.md → Baker),
screenshot (writes a PNG, replies with its path), sounds (clips and live voices), and lua.

- `lua <code>` runs against `game_world`. `lua <world> -` (code on stdin) points the World / Entity calls at
  that world: give a play world's index (`worlds`; it shares the level's title) to test collision and sound.

- `screenshot <view>` is the view's render target: the 3D scene only. Icons, the gizmo and panels are ImGui,
  drawn later, so they need `screenshot ui`: the whole main window as shown, copied from the swapchain
  inside the next frame and answered then. Panels dragged out into their own OS window aren't in it.

- Commands run on the main thread between frames, polled before `ui_update`, with no threads.
- The reply's first line is `ok` or `error`. Entity text uses the scene `[entity]` format.
- Use it to verify engine changes yourself, cheapest check first (the ladder in CLAUDE.md): text
  replies before screenshots. Don't hand back an unverified build when the engine can be driven.
- **Launch options** are for what has to be decided before the D3D12 device exists: `--renderdoc`, and
  `--gpu-validation` (D3D12 GPU-based validation, for a bad descriptor index or resource state; off by
  default because it slows the first frame by seconds). `blimpctl restart [options...]` relaunches a running
  engine with exactly those options (none = plain), and refuses while anything is unsaved. Remote sockets
  aren't inherited, so the relaunched engine gets the port.
- **RenderDoc** (`src/editor_renderdoc.odin`): it's active only when the engine is started with
  `--renderdoc`, or launched from RenderDoc, because it has to hook D3D12 before the device exists.
  - `blimpctl capture` captures the next frame (one `renderer_dx_update`) to `out/captures/*.rdc`
    and replies with the path. `captures` lists them; `rdui [i]` opens one in qrenderdoc.
  - To read a capture: `"C:/Program Files/RenderDoc/renderdoccmd.exe" convert -f X.rdc -o X.xml -c xml`.
    The XML holds every API call with its arguments: draws, ExecuteIndirect counts, barrier
    sync/access/layout. `renderdoccmd thumb` extracts the final image.
- The build is `odin run build.odin -file` (there is no build.exe). Close a running engine first,
  since Windows locks `bin/blimp.exe`.

