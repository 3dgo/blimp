# Assets


Everything loads at init and never changes at runtime. No streaming, no eviction, no
manifests, no per-asset meta files. This is deliberate — a prior, more complex asset
system was cut for exceeding current needs.

**Hot reload** (debug builds, `asset_hot_reload.odin`) doesn't change that: it reloads *everything*
of a kind, as init would. A `ReadDirectoryChangesW` watcher on `assets/` and `assets_engine/`, polled at
the top of each frame, waits 0.3 s after the last change (Max writes `.bin` then `.gltf`), then:
- `.gltf .glb .bin .png` → `asset_system_reload`: GPU idle, the asset arena and GPU asset buffers
  thrown away and rebuilt. Entities keep working because the keys they hold are interned in their own
  arena, `asset_keys` (`asset_intern`), which outlives every reload — so do undo snapshots and the
  clipboard. Anything that keeps an asset key must intern it (`entity_intern_keys` after reading
  fields from text). Play worlds' physics are rebuilt with it.
- `.slang` → every pipeline recompiled, all or nothing (`render_shaders_reload`, a fresh Slang session).
- `.wav .ogg .mp3 .flac` → every sound clip (`sound_reload`).
- `.luacn` → transpiled to its `.lua` (`common.luacn_convert`, shared with the build's codegen); `.lua` →
  play worlds running it rerun it from the top, start included; `main.lua` reruns (`lua_reload_script`).

**Collision models.** A mesh named `<model>_col` in a kit is `<model>`'s static collision (docs/gameplay.md →
Physics): imported like any model, cooked at load into Box3D mesh data (`asset_system.collision`, keyed by the
*render* model), offset by where its node sits relative to the model's node, and left out of the kit's
layout. It's never drawn. Authored in Max next to the visible mesh. It's what an entity with `collision = Collision_Mesh` (the
default) collides as; an entity can use its render mesh or bounds instead (docs/gameplay.md → Physics).

**Sound clips** (`world_sound.odin`): every `.wav .ogg .mp3 .flac` under `assets/` and `assets_engine/`,
decoded at startup by miniaudio, keyed by project path like a texture (`assets/sounds/door.wav`).

**A glTF file is a kit** — a set of related models plus their textures, authored as one
file and (later) openable as a scene to copy models from into the game scene. Placing
content is copying models out of a kit, not importing one mesh per asset. This is
intentionally narrower than Unity/Unreal's general-purpose one-asset-per-mesh model:
it's simpler to author and use, and it's *why* a glTF holds multiple models, textures
live with their kit, and textures aren't deduplicated across files.

The kit's glTF **scene is a display/preview layout** — the DCC arrangement, one entry per
node, shown when you open the kit to browse it. Node transforms are **display-only**:
copying a model into the game scene does *not* carry the kit transform; the game entity
gets its own. Two nodes referencing the same mesh are the **same model key** — geometry is
never duplicated. This is how a kit offers **material variants**: one geometry (stored
once) with different material choices you pick at copy time (the mesh's material or an
entity `mat_override`). Because glTF assigns material per mesh-primitive (not per node),
variants appear as separate primitives sharing the same accessors — so enabling this
cleanly means the importer **dedups geometry by glTF accessor** (it currently copies
per-primitive). Future work, not built yet.

The importer reads the default scene's node hierarchy (`gltf_world_matrices`) and records one
`Kit_Node {name, model, position}` per mesh node in `asset_system.kits`. Each node's composed
world **rotation/scale is baked into the mesh vertices** (the exporter puts the Z-up→Y-up
conversion in node matrices). Its world **translation** is not baked: it becomes the entity
position when the kit opens as a world, so the layout matches the DCC. A mesh referenced by
several nodes bakes the last node's rotation/scale, since geometry is stored once.

**Artist workflow (3ds Max).** One `.max` per kit, saved under `assets/` next to its export with
the same base name (`assets/models/cars.max` → `cars.gltf` + `cars.bin`). Shared textures live
under `assets/` too and the Max scene references them there. The scan imports only `.gltf`/`.glb`
and textures load only when a glTF references them, so `.max`, `.psd` and autobackups in `assets/`
cost nothing. Export `.gltf`, not `.glb`, so textures stay external and are shared by path. Setting
the Max project folder to the repo root keeps bitmap paths relative, but it isn't required (absolute
URIs are re-rooted, see below). The game build (`odin run build.odin -file -- game`) copies `assets/` and
`assets_engine/` without the DCC sources (`.max .psd .blend .bak .luacn …`, `GAME_SKIP_EXTS`); there is no cook step.

- Scan for glTF files, parse each, load all meshes and textures into RAM and VRAM.
  Textures are **not** scanned up front — each glTF pulls in the images it references.
- Keys: **project-relative, forward-slash path** plus a name, e.g. model
  `assets/models/car.gltf:body`, mesh `…:body:0` (primitive), material `…:mat_name`,
  image `assets/models/colormap.png`. Path form makes keys identical across machines and
  OSes (never absolute) and find-and-replaceable in plain-text level files on rename.
  Assert on duplicate keys. No UUIDs.
- **Textures are shared across kits**, decoded and uploaded once. Both `.gltf` and `.glb` are kits.
  - **External** (`.gltf` with a file `uri`): keyed by the project-relative image path, e.g.
    `assets/models/colormap.png`, so every glTF referencing that file gets the same image.
    - The gltf2 lib replaces `Image.uri` with the file's bytes, but the original string survives
      in `data.json_value` (`gltf_image_uri`). Don't patch the lib for it.
    - The URI is percent-decoded first.
    - An absolute URI (`E:\...`, `file:///E:/...`, which a DCC writes when no project folder is
      set, possibly from another machine) is re-rooted at its first `assets/` or `assets_engine/`
      directory that exists here (`gltf_image_path`). A texture outside the project warns and
      loads as white: textures must live under the project.
  - **Embedded** (`.glb` buffer views, data URIs; 3ds Max embeds every texture into every `.glb`):
    keyed `gltf:image_name`, and shared by content. A 64-bit xxhash plus the byte length maps to the
    first decoded copy, and a later copy only registers its own key for that image.
  - The startup log line `N images under M keys` shows sharing (M > N).
- Per-glTF import wraps its scratch (parse data, decode staging, temp keys) in a temp-arena
  checkpoint (`arena_temp_begin`/`arena_temp_end`); do **not** rely on `gltf2.unload`, it
  frees against `context.allocator`, not the load allocator, so it wouldn't clean up here.
- **Content determines format, directory determines role.** glTF contents identify
  skinned vs static vs animation-only (`skins`, `animations`, `meshes`); directory
  (`kits/`, `characters/`, `props/`) identifies intent.
- Animation-only files bind to skeletons by node **name**, not index. Fail loudly on mismatch.
- Import settings by convention (`_n` suffix → BC5) plus one rules file. Sidecars only as
  per-asset exceptions.
- Upload through a fixed staging ring (~64MB) on the copy queue, never one allocation the
  size of the scene.

Habits to keep even though the systems that need them don't exist yet:
- Mesh handles and bindless descriptor slots are table slots, never load order.
- Mip tail first in the cooked texture layout.
- Bounds in the mesh record.

