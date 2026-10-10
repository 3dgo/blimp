# Rendering, lighting and PS1 look

## Rendering

Simple forward. **Not** clustered — that needs hundreds of dynamic lights to be worth
evaluating. The GPU-driven architecture is indifferent to shading model, so a higher-res
PBR version later is additive.

- **Coordinate system: left-handed, Y-up, +Z forward.** Front faces are **clockwise**
  (`FrontCounterClockwise = false`, cull `BACK`). glTF (right-handed, CCW-front, +Z toward
  viewer) is converted at import by a single-axis reflection (`-X`, keeping +Z as forward)
  **and** a per-triangle winding swap — *both* are required for correct CW front faces (the
  pipeline's NDC→viewport Y-flip is the extra flip that makes reflection alone insufficient).
  Don't remove the swap.
- **Reversed-Z**: float depth, swapped near/far, `GREATER` compare, clear to 0.
- **Render to a float HDR target**, quantize only at the end of the post chain. Each view has
  an `R16G16B16A16_FLOAT` scene target (`hdr_tex`) and an `RGBA8_UNORM` display target
  (`tex`) that ImGui samples and screenshots read. `render_post.odin` (`post.slang`,
  fullscreen passes) resolves one into the other; debug lines draw after it, onto the display
  target, so their colours stay exact. A `.Retro` view also has a scene-size intermediate
  (`post_targets`): the signal (`RGBA8`).
- **The scene target and depth are the display size ÷ `scene_scale`, rounded up**
  (`dx.Viewport_Options.scene_scale`). The scene VS squeezes NDC by `sceneCover` so the image
  lines up with the display pixel for pixel while the projection stays the display's (CPU
  picking is unaffected). Depth is `R32_TYPELESS` with a DSV and an `R32_FLOAT` SRV: passes at
  the display size can't bind it as a DSV, so debug lines depth-test against it in the shader.
- **Render mode** is per view (`Render_View.mode`, viewport toolbar). `.Retro` (default, and
  always in release): the effects of the shown world's `Retro_Settings` (see Retro look below).
  `.Clean`: scale 1, none of them. Same scene shaders and passes; only frame constants, the
  scale and the post passes differ, so the two can't drift. Affine UVs are a second
  `noperspective` varying blended by `affine`, since interpolation can't switch at runtime.
  Debug lines don't snap, so an outline can sit up to a scene pixel off its jittering mesh.
- **Shading is linear.** Colour textures are `_SRGB` views (decoded on sample); glTF material
  and vertex colours and light `color` are linear (the picker shows light colour as sRGB,
  `widget:linear_color`). **No exceptions to the tonemap:** the world `background` and the fog
  colours are linear scene light too (`widget:linear_color`); the scene target clears to the
  background and every pixel takes exposure, the tonemap and the dither. So a picked colour shifts
  through ACES and follows exposure: sky and fog colours are judged in the engine. Chosen over
  pinning picked colours with an inverse tonemap, for one pipe with no special cases. The sky (see Sky)
  is a fullscreen pass writing linear light before the opaques (no mesh: one would fight the
  baker's bounds and misses, the shadow pass and the far plane); nothing reads the clear alpha.
- Light data lives in a GPU buffer indexed from the shader, not root constants.
- **The frame is three calls the app makes** (`app_run`): `renderer_dx_draw_frame` (each world's draw
  mirror staged, shadows, every view's scene + post + debug lines, the backbuffer cleared and bound),
  then the app's `ui_draw`, then `renderer_dx_submit` and `renderer_dx_present`. The renderer never calls
  the UI or the editor: the editor's debug lines are already in `debug_draw` when the frame starts.
- **Probe data is world data.** `Probe_Grid`, its CPU maths (the mirror of `shading.slang`) and the
  `.probes` sidecar are `world_probes.odin`; `render_probes.odin` only creates and stages the GPU copy.
- Hardware floor is Resource Binding Tier 3 (~2015 GPUs). No fallback path. Log
  `ResourceBindingTier` and `DXGI_QUERY_VIDEO_MEMORY_INFO` at startup.

### Naming

Entity places a model → model expands into mesh instances → cull produces draw commands.

- **Entity** — placed thing. `model`, `transform` index, optional `mat_overrides` slice.
- **Model** — CPU-only list of mesh indices. Never uploaded.
- **Mesh** — one glTF primitive.
- **Mesh_Instance** — one entity-mesh pair, produced by expansion at level load.
- **Draw command** — emitted by the cull pass, one per visible mesh instance.
  - Visible means `entity_drawn`: Renderable, Enabled, and not Hidden.
  - Undrawn entities still get their transform and mesh instances, so indices don't shift when
    something is hidden. They just get no draw command, no selection box, and picking and marquee skip them.

Worked example: 3 entities (1× a 2-mesh model, 2× a 3-mesh model) → 5 meshes,
3 transforms, 8 mesh instances, ≤8 draw commands.

### Buffers

```odin
Vertex_Attr   :: struct { normal: [3]f32, uv: [2]f32 }
Skin_Vertex   :: struct { joints: [4]u8, weights: [4]u8 }

Mesh :: struct {
    index_offset, index_count:   u32,
    vertex_offset, vertex_count: u32,
    skin_offset:   u32,   // INVALID for static
    material:      u32,   // default only; shader never reads this
    bounds_center: [3]f32,
    bounds_radius: f32,
}

Material :: struct {
    albedo_tex, emissive_tex: u32,   // bindless descriptor indices
    base_color: [4]f32,
    emissive:   [3]f32,
    flags:      u32,                 // alpha-test, unlit, two-sided
}

Transform     :: struct { world, prev_world: matrix[3,4]f32 }
Mesh_Instance :: struct { transform, mesh, material, shading: u32, tint: vec4, bone_offset: u32 }

Draw_Command :: struct {              // 24-byte stride
    instance_index: u32,              // root constant in the command signature
    args:           d3d12.DRAW_INDEXED_ARGUMENTS,
}
```

Geometry is three flat arrays — `indices`, `positions`, `attributes` — plus `skin_data`
for skinned meshes only. Positions are separate so depth and shadow passes touch less.

Material overrides are authored on the entity as an optional slice (nil = none) and
**resolved during expansion**, so the shader never branches on them.

Update frequencies, which drive upload strategy:

| Data | Written |
|---|---|
| geometry, mesh table, material table | once at init |
| mesh instances | level load |
| transforms, bone matrices, lights | per frame, CPU |
| draw commands + counter | per frame, GPU |

### Indirect draws

- Command signature: `CONSTANT` (1 u32) + `DRAW_INDEXED` (5 u32) = 24 bytes. The root
  constant carries the instance index because there is no CPU between commands to bind
  anything.
- Shader reads the constant → `mesh_instances[i]` → transform and material.
- Use `ExecuteIndirect` even while commands are filled on the CPU, so switching to a
  compute cull pass changes only who writes the buffer.
- One command buffer, one contiguous range per PSO bucket (`World_Render.draw_first` /
  `draw_count`), one `ExecuteIndirect` each. The buckets are the entity blends, below; the
  shadow pass draws the first two ranges.

### Shading models and blend

Two entity fields, two different axes (`entity_schema.ini`):

- **`shading`** — how a surface takes light, listed cheapest first: `Unlit`; `Gouraud` (light
  per vertex, diffuse only: the PS1's); `Lambert` (per pixel, smooth normals, diffuse only);
  `Flat` (Lambert with the face normal from derivatives); `Phong` (per pixel, Blinn-Phong
  highlight). Gouraud's shadows are per pixel: an interpolated shadow loses any edge between
  vertices, so the VS hands over the first 4 shadowed lights' light separately (`VertexLight`)
  and the PS shadows each; any more shadow per vertex. `Default` means the level's `World_Settings.shading` (default Lambert), resolved by
  `entity_shading` while building instances, so the shader only sees a `ShadingModel` on the
  instance. A shader branch, uniform per draw, not a PSO: one pipeline for every model.
- **`blend`** — how pixels combine: `Opaque`, `Cutout` (discard below alpha 0.5), `Alpha`,
  `Additive`. Each is a PSO and a draw bucket, drawn in that order. Alpha and Additive test depth
  but don't write it and don't cast shadows. Alpha draws are sorted back to front by their mesh bounds'
  centre, from the eye of the first view showing the world (views share the world's commands, so a second
  view of the same world gets the first's order). Additive is order-independent and stays in entity order. A Cutout casts its whole quad, since the shadow pass has no pixel shader.
  The alpha is the material's colour × texture × vertex colour.

All lighting lives in `shading.slang`: `light_surface` (everything lighting a point) and one
`shade_*` function per model behind `shade()`; Gouraud's share runs in the VS via
`vertex_lighting`. A new model is a `ShadingModel` + `EntityShading` member, its case in
`entity_shading`, a `SHADING_*` constant, and a function + case in `shade()`.
- One command per mesh instance is fine. Batching identical meshes needs sort + compact
  and gives up the root constant. Only if it profiles badly.

### Skinning

- Same shared buffers. `Skin_Vertex {joints [4]u8, weights [4]u8}` in a parallel stream (`skin_buffer`,
  asset) with `Mesh.skin_offset` (`NO_SKIN` for static meshes).
- Skin matrices (`model × inv_bind`, claude/animation.md) per world per flight (`World_Render.bones`, built in
  `buffers_build_scene` like lights) with `bone_offset` on the instance; `NO_BONES` draws the mesh as stored,
  which is its rest pose. The shader branch (`skinMatrix`, utils.slang) is uniform per draw.
- Vertex skinning, not compute skinning, in model space before the entity transform, in both scene.slang and
  shadow.slang. Vertex snapping comes **after** it, in clip space.

### Particles

Emitters are entities; particles are not. A GPU-resident particle buffer updated by
compute, drawn as one instanced draw per system generating quads from `SV_VertexID` and
`SV_InstanceID`. Additive blending needs no sorting, which covers most of the target look.
Start CPU-side into a dynamic vertex buffer.

### Alignment

- Constant buffers: 256 bytes, size and offset. Placed resources: 64KB. Texture upload
  placement: 512. Row pitch: 256.
- HLSL packing fails silently. `float3` + `float` packs into 16 bytes; `float3` + `float3`
  does not. Pad every GPU-facing struct to a 16-byte multiple with named fields and assert
  `size_of` matches the HLSL side.
- A matching `size_of` doesn't catch an interior shift: in a cbuffer a vector that would
  straddle a 16-byte row moves to the next one and every later field reads off. Odin has no
  attribute for this rule, so constant-buffer structs also `#assert` each vector field's
  `offset_of(T, f) % 16 + size_of(f) <= 16` (see `Frame_Constants`). Structured buffers pack
  tightly and don't need it.

### Debug layer

Debug builds enable the D3D12 debug layer and break on errors. GPU-based validation is off by
default: it patches every PSO on first use (over 2 s on the first frame of the castle map) and
slows every frame after. Launch with `--gpu-validation` (or `blimpctl restart --gpu-validation`)
when chasing a bad descriptor index or resource state; claude/editor.md has the launch options.

No CPU-side fence/hazard assertion layer (dropped from the build order 2026-10-10): every buffer the CPU
writes per frame has a copy per frame in flight (`FRAMES_IN_FLIGHT`), one fence wait starts the frame, and
closes wait idle, so the CPU-overwrites-in-flight race can't happen without breaking that pattern; GPU-side
barriers are what GPU validation checks. Build a check only around a buffer that actually flickers.

Slang caches each entry point's DXIL per session (`Slang_Compiler.entry_code`), so pipelines
that share an entry point (every scene blend uses `vert_main`) compile it once. Shader hot
reload starts a new session, which clears it.


## Lighting

Baked probes for indirect, realtime direct with hard shadows.

- **Uniform probe grid** baked by a CPU ray tracer. Probes light static and dynamic
  geometry both. No lightmaps — the real cost there is per-instance atlas packing sized by
  world-space area, not the baking.
- Per probe: **L2 SH irradiance** (9 coeffs × 3) plus a small **octahedral depth map**
  (8×8, mean and mean² distance).
- **Chebyshev visibility test** at sample time solves leaking:

  ```
  variance = mean2 - mean*mean
  vis = d <= mean ? 1 : variance / (variance + (d - mean)^2)
  ```

  Fold into each of the 8 trilinear weights, renormalize. Bias `d` slightly toward the
  probe or surfaces self-occlude. Clamp variance to a small minimum.
- This is the **DDGI format**. A realtime version later swaps only the update mechanism.
  Keep the grid uniform for that reason — DDGI can't use adaptive subdivision.
- **Multi-bounce**: re-run the trace with the previous pass as the radiance source, two or
  three passes. Average linear albedo per material from the 1×1 mip at cook time — average
  in **linear**, not sRGB. Clamp below ~0.9 so energy converges.
- Bake **irradiance, not final color**. The baker never samples textures and albedo changes
  don't require a rebake.
- Per-entity **cast-indirect flag** excludes dynamic and clutter geometry from the bake.
- **Per-mesh baked AO** (vertex colors or a small UV2 texture) multiplied against probes for
  contact darkening. Per-mesh means no atlas packing.
- **Emissives carry the composition** — lamp glass, windows, candles. Unlit emissive
  materials plus tight bloom, separate from the lighting solve. Built: `Material.emissive` × its texture
  (claude/assets.md) is added after shading in every model, Unlit included, × the entity's tint, so Color ×
  Intensity dims or brightens a glow (a script can put it out with its lamp). On screen it lights nothing
  else. The bake sees it: a ray hitting it gets the material's emission (emissive × its texture's average,
  `material_emission`) × the entity's tint, into layer 0, so it lights the room through the probes. Layer 0
  means a baked glow doesn't follow light groups: switch the lamp off and its shade's bounce stays. Hidden in
  the light-only debug views. Bloom isn't built yet.
- **Thin translucency** (`Material.translucency`, from glTF transmission, claude/assets.md): a surface also
  takes that share of the light on its back face, diffusely (`light_surface`; Gouraud adds it per vertex). Its
  shadow is looked up from the back side (offset along −N), or the surface would shadow itself. Because real
  lights do it, a lamp shade's glow follows the lamp: off, flicker, light groups, with no script. The bake
  does the same (`bake_direct`: the back's light × translucency, its shadow ray leaving from the back side),
  in the light's own layer, so the shade's bounce follows the lamp's group too. Not an emissive, which glows whatever the lights do; that's for things that are the light.
- **Realtime light falloff is per light** (`falloff`), over `range` = inner, outer radius;
  every mode reaches exactly zero at `range.y`. Not photoreal by default — pick per light:
  - *Inverse Square* (default): `intensity / d²`, held flat inside `range.x` (the source's
    size), windowed by `saturate(1 - (d/r)⁴)²` (Karis 2013; Unreal / Unity URP). Intensity
    is the light at 1 unit.
  - *Linear*: full inside `range.x`, straight down to zero at `range.y`.
  - *Smooth*: full inside `range.x`, smoothstep to zero at `range.y`.

  Directional intensity is unattenuated. Spot cone: full inside `inner_fov`,
  `saturate((cosθ - cosOuter) / (cosInner - cosOuter))²` to zero at `fov` (both full angles,
  inner clamped to outer). No 1/π on diffuse, as in URP.
- **Cylinder** light: a spot whose beam is a cylinder, not a cone. Parallel rays along +Z
  from a disc at the entity (`L = -forward`, like a directional light, nothing behind the
  disc). The falloff runs along the beam over `range`; across it the edge fades like the
  spot's cone, full inside `inner_radius`, squared to zero at `radius`.
- Only two or three genuinely-moving realtime lights.
- **Headlight**: a world with no drawn lights (a kit, a new level) is lit by a white, intensity-1
  directional light from each view's eye (`L = V`, in the scene shader), so a model can be looked at
  before anyone places a light. Per view, unshadowed, never baked; the first light entity turns it off.
- **Light groups** (`world_light_groups.odin`, Quake lightstyles): every light has `light_group`. Group 0
  is static; groups 1–4 are named in World Settings (`light_groups`: name, starting scale, flicker pattern —
  a letter per 1/10 s, a = 0, m = 1, z ≈ 2, stepped). A group's scale multiplies **everything its lights
  give**: their realtime intensity in the light buffer, and their own probe layer (the baker bakes each
  group that has lights into a separate SH layer, bounces included — light adds up, so a layer scales
  exactly). The power goes out = `World.set_light_group("electric", 0)`; candles in another group keep
  flickering. Runtime overrides (`World.light_group_override`, from Lua or the Lighting menu) are never
  saved. Cost: one grid of memory and one shader lookup per lit group. Emissives don't follow groups yet.

### Baker

CPU tracer. Not DXR, not GPU hemicube — baking is offline, so a breakpoint on a bad texel
is worth more than a 100× speedup.

- **Two-level BVH** (`asset_bvh.odin`), both median-split by one builder over primitive bounds.
  `Mesh_BVH`: one per mesh, object space, built at asset load (also editor picking).
  `Scene_BVH`: top level over a list of mesh instances (entity × mesh, world bounds) the caller
  picks; a leaf sends the ray into its mesh's BVH through the inverse entity transform. Built on
  demand as a snapshot — the baker builds one per bake (`bake_scene_bvh`) over `entity_bakes` (drawn,
  `Static`, `Cast_Indirect`). The asset layer never reads a world: the baker hands it the instances.
  Closest-hit and any-hit (shadow rays) queries, iterative with a fixed stack.
- **Indirect only.** Every light stays realtime direct; a light reaches a probe only off a
  surface it lit. The sky the views show (the sky texture, else `background`; × `bake.sky_intensity`) is in
  the probes unless `bake.sky` is off. A light bakes by the same rule as geometry, `entity_bakes`: clear `Static` for one that
  moves (its bounce would stay where it was placed), `Cast_Indirect` for a fill or rim light that
  shouldn't bounce. Its `indirect` field (default 1) scales its baked bounce, not its direct light.
- **Grid**: the static geometry's bounds plus one `probe_spacing` all round (`bake.bounds = Auto`), or
  a manual box (`bounds_min`/`bounds_max`), at most `MAX_PROBES`. Per pass, every probe casts
  `bake.rays` rays (16–4096) on a **Fibonacci sphere** (the same set everywhere, so a bake repeats
  exactly). Miss → sky. Front-face hit → `albedo × (direct + previous pass's grid sampled there)`;
  direct is the scene shader's diffuse with one shadow ray per light that reaches the point, for the
  lights whose `shadow` (Cast Shadow) is on, as on screen. Back-face hit → black, and
  counted (a probe with > 25% is "buried"). `bake.bounces` passes (1–8) = that many bounces.
- **Quality presets** (`bake.quality`): Draft 64 rays × 1 bounce, Medium 256 × 3 (the default), High
  1024 × 4. Picking one in the window fills rays and bounces; editing either makes it Custom. Only
  rays and bounces are read by the baker; the preset is a label.
- **Projection**: Monte Carlo `c_i += L·Y_i·4π/N`, convolved with the cosine lobe and **divided by
  π**, so the shader's indirect is `albedo × max(0, sh_eval(N))` — the same no-1/π convention as
  direct, so what's lit on screen is exactly what bounces.
- Front faces: `cross(v1 − v0, v2 − v0)` points out (clockwise front, left-handed).
- **Threads**: a bake runs on its own thread, one at a time (`bake_job`), so the editor keeps running.
  `bake_start` snapshots everything the trace reads (scene BVH, lights, sky table, rays) into the bake's
  own arena, freed when it ends; past that the trace reads only assets, so asset hot reload waits for it.
  Each pass is a `parallel_for` (`basics.odin`) over probes on every core but one: `core:thread` workers
  claim chunks off one atomic counter; each probe writes only its own slot, and the body never allocates
  or logs. Progress is an atomic count of probes traced.
- **Per pass on screen**: a finished pass is a whole grid (that many bounces), so `bake_update`, at frame
  start, copies it into the world's grid and GPU buffer; mid-pass data is never shown. **Cancel** drops
  the unfinished pass and finishes with the passes done (shown, saved); cancelled during the first, the
  old grid stays. Closing the level cancels its bake without saving. blimpctl `bake` waits for the end.
- **Albedo**: `asset_system.material_albedo`, computed at load, kept beside `Material` (whose
  layout is the GPU's).
- **Storage**: the level's binary sidecar `foo.level` → `foo.probes` (version 3: header with the layer → light-group map, then each layer's `Probe_SH`, then one `Probe_Depth` per probe; an older version is refused, rebake),
  written by the bake and read by `scene_load`. A bake is **not an edit**: no undo step, nothing
  unsaved. The grid has its own arena (`Probe_Grid.arena`), freed whole on rebake. A play copy
  lights with its level's grid; a play world a level switch loaded from a file has its own (`world_lighting`). The GPU copy is one buffer per world, replaced after
  `renderer_dx_wait_idle`, so passes land at frame start (`bake_update`).
- **Shader**: `Probe { float c[27]; float _pad; }` (112 B, a float array so structured-buffer
  layout can't differ from Odin), manual 8-tap trilinear (`probe_irradiance`) — manual so the
  Chebyshev weight can fold into each corner. No grid → flat `AMBIENT`.
- Settings are `World_Settings.bake` (saved as `bake.*` keys in `[world]`), edited in the **Probe Bake
  window** (`ui_bake.odin`, its own toolbar button): settings (a hand-drawn form — Quality, Sky,
  Probe Grid; a manual box shows as yellow scene lines while the window is open, with a Fit to
  Geometry button and the probe count it gives), Bake, last-bake stats, and the **probe
  atlas** — a picture of the grid, not lighting data: each probe an 8×8 octahedral tile of `sh_eval`
  (centre up), one block per layer seen from above, at the exposure it was baked with; hover names
  the probe, outlines its tile and draws a yellow square on it in the world's views; double-click frames it. Built on the CPU with the grid (`probe_grid_atlas`), shown through an ImGui-heap SRV.
- Debug views, per view from the toolbar's **Lighting** menu (`Render_View.lighting`, `probes_off`,
  `indirect_scale`, all frame constants), in menu order: Full Lighting, Direct Only, Indirect Only,
  Lighting Only (white albedo), Probes Only (probe light on white); baked probes vs the flat ambient; an indirect multiplier;
  Show Probes (six spokes per probe coloured by `sh_eval` along ±X/±Y/±Z). blimpctl `bake` / `probe`.
  Wireframe and collision are the toolbar's Debug view menu (claude/editor.md).
- Build order: BVH and tracer → uniform grid with naive interpolation → **observe the
  leaking** → add the visibility test. Don't add the fix before seeing the problem. **Done up to the
  visibility test.** Next: per-mesh AO.
- **Visibility** (`.probes` v3): per probe one `Probe_Depth`, 8×8 octahedral texels of (mean, mean²)
  distance, float32 (512 B; f16 loses the variance to cancellation), geometry only so one per probe, not
  per layer. It's recorded in pass 0. Each texel takes the rays near its direction, weighted
  `max(0, cos)^50` (a texel × ray table built once per bake), distances clamped to 2 spacings, misses
  counting as that.
  - A **buried** probe (over 25% back-face hits) gets an all-zero map, so Chebyshev gives it about zero
    weight everywhere. That's the "weight 0" step, done by the same test.
  - Sampling (`probe_visibility`, the same in `world_probes.odin` and `shading.slang`) moves the point
    0.2 spacings along the normal first. Per corner it multiplies the trilinear weight by DDGI's smooth
    backface term `((dot(toProbe, N) + 1) / 2)² + 0.2` and by Chebyshev cubed, with variance floored at
    `1e-3 × spacing²`, floored at 1e-6, then renormalized.
  - The bake's own bounce lookups use it too (from pass 1), so bounces don't leak either.

### Shadows

- **Hard, low-res, unfiltered.** 512² or 256², point sampled. Soft PCF edges read as modern
  and break the look.
- Point lights use cube maps (6 faces). Cascades are a directional-light technique; 2–3
  cascades for exteriors if needed.
- **Every slice redraws every frame.** A static cache (one world-wide hash of the casters) was tried and
  removed: any moving caster, an animated character included, invalidated every slice, so in play it never
  hit. If the shadow pass ever shows up in `timings`, the fix is a per-slice cache keyed on the casters
  whose bounds touch that slice, not the world-wide one.
- **Implementation** (`render_shadows.odin`, `shadow.slang`): one `R32` texture array per world,
  `MAX_SHADOW_SLICES` (32) × 512², shared by its views. Every shadow is a slice with its own
  reversed-Z camera: directional = an ortho box centred on the entity (`size` x, y across, z deep;
  drawn when selected), cylinder = ortho over its beam, spot = a square frustum of its `fov`, point =
  six 90° slices along the world axes (the "cube map": the scene shader picks the face by the major
  axis, so one sampling path covers every type). Lights with `shadow` (and nonzero intensity) claim
  slices in entity order; when they run out the rest light unshadowed, with one warning.
- The shadow pass draws **all drawn geometry** from the same indirect commands as the scene, depth-only
  (no PS), cull none (single-sided walls must still block light). One `Shadow_View` per slice (256 B)
  in a mapped UPLOAD buffer: the root CBV for that slice's draws, and a structured buffer for the
  scene pass. The scene pass `Load`s one texel per light: no sampler, no filtering.
- Acne: slope-scaled + constant depth bias on the casters, and the receiver moved 1.5 shadow texels
  along its normal (`GPU_Light.shadow_texel`; scaled by distance for spot and point).
- **A light inside its fixture** (a bulb in a lamp shade): the light's `shadow_cull_near` is its shadow
  cameras' near plane (point, spot; at least `SHADOW_NEAR`), and where a cylinder's box starts along its beam.
  Nearer geometry isn't rasterized into its map, so it casts no shadow from that light, and the shader reads
  a receiver in front of the near plane as lit (`ndc.z > 1`). The bake's shadow rays stop that much short of
  the light. Per light, not per caster: the shade still shadows every other light, and there's no light
  linking. Moving the six cube cameras apart instead was rejected: the faces only tile because they share
  the light's position as apex, and the shader picks a face by direction from it, so offsets open seams.
- A dynamic object lit by probes over baked environment looks detached unless it casts a
  shadow onto static geometry. Grounding matters more than lighting sophistication on the
  character.


## PS1 art direction

Reference: Victorian horror, lamp-lit interiors, cold blue against warm orange, almost no
directional light.

Era tells, most recognizable first:

1. **Vertex jitter** — quantize `pos.xy / pos.w` to a low-res grid in the VS, multiply back.
2. **Affine texture mapping** — `noperspective` on the UV varying.
3. **Low resolution** — 384×216, which scales ×5 to 1080p exactly. Non-integer point-sampled
   scales shimmer.
4. Low-poly silhouettes, small textures, point filtering, no mipmaps.
5. **Dithering** — 4×4 Bayer, 5 bits per channel. Least conspicuous, but its absence shows
   as banding in fog, which dominates these scenes.

**Post chain order: tonemap → LUT → quantize + dither → upscale.** The tonemap is ACES
filmic (Hill's RRT+ODT fit) after `2^exposure` (world setting, EV), then sRGB-encoded. Quantize in display
space, not linear — these scenes sit at the bottom of the value range where linear 5-bit
gives almost no levels.

### Sky

`World_Settings.sky` (`texture`, `intensity`, `rotation` in degrees about +Y): an equirectangular 2:1 PNG from
`assets/` (every PNG loads at init, claude/assets.md; by convention skies live in `assets/skies/`), drawn in place of the
background colour. No texture: the background colour, as before. A learning walkthrough is in `docs/sky.md`.

- **LDR, sRGB × intensity; no HDR, no cubemap.** HDR skies exist for the sun, which here is a directional light
  with its own direct light and shadows; the sky only adds soft fill. One PNG paints in any tool and loads
  with the existing loader; a cubemap is six faces and a new texture type for less stretch at the poles.
- **The pass** (`sky.slang`, `renderer_dx.sky`): one fullscreen triangle into the scene target right after the
  clear, before the opaques, no depth test or write. Its pixels keep depth 0, so the fog sees a ray that hit
  nothing (distance fog's `max_opacity` decides how much shows through it). Direction per pixel as the fog finds it: `scene_ndc` (from
  `sceneSize`, no texture read, so it works in the scene pass) then `view_ray_dir`; an ortho camera sees one
  colour. `u = atan2(x, z) / 2π + 0.5 − rotation` (+Z at the centre, +X to its right), `v = acos(y) / π`.
  `SampleLevel(…, 0)`, not `Sample`: u wraps from 1 to 0 behind the camera, and derivatives would pick the
  smallest mip there and draw a seam. The frame's sampler, so point-sampled in retro views like the scene.
- **The bake** sees the same sky: a miss takes the texture in its direction, box-filtered at bake start to a
  32 × 16 table of linear radiance (probes hold low-frequency light; a few hundred rays on the full texture
  would only add noise), mapped like `sky.slang`, × `bake.sky_intensity`. No texture: `background` ×
  `bake.sky_intensity`.

### Fog

`World_Settings.fog`, all in the post signal pass (`post.slang`) along each scene pixel's ray (near plane to
scene depth, through `Frame_Constants.inv_proj`, undoing the `sceneCover` squeeze first: free camera,
perspective and ortho camera entities alike). Scene light **before** the tonemap: `scene × T + fog colour ×
(1 − T) + halos`, then exposure, tonemap and the quantize, so fog bands get the same dither as everything
else. Depth 0 (the clear) is a ray that hit nothing: length "infinity" (1e6), so the background is fogged
like any pixel. Blended surfaces don't write depth and take the fog of what's behind them. **Analytic, not
ray-marched or froxels:** froxel fog hides its noise with temporal reprojection, which smears like TAA and
lags; this has no history and reacts the same frame. A learning walkthrough of how it's built is in
`docs/fog.md`.

`Fog_Settings` is laid out as the inspector shows it: the shared colour first, then each part under its switch.

- **One colour** (`color`, linear: see "Shading is linear") for both fogs; the halos take their lights' colours.
  Two colours mixed by each fog's share of the optical depth were dropped: the same colour was always picked.
- **Distance** (`distance_fog`, `start`, `end`, `max_opacity` 0..1, default 1): the PS1 ramp, transmittance
  linear from 1 down to `1 − max_opacity`. Below 1 the sky (a miss, "infinitely" far) shows through, and so does
  far geometry: on every pixel, not only misses, so a distant mountain fades like the sky behind it rather than
  showing as a flat fog-coloured cutout. A cap on the ramp, not on density: density is per metre, and a long
  enough ray reaches full fog at any density.
- **Height** (`height_fog`, `height`, `density` per metre there, `falloff` metres per e): exponential ground
  mist; its optical depth is closed form, capped at 100 (a ray down into the void would otherwise reach
  infinity). **Not capped by `max_opacity`:** looking up, its optical depth to infinity is finite
  (≈ density × falloff / dir.y), so on the sky it is thick at the horizon and clear overhead by itself. A cap on
  the product of both fogs flattened that gradient whenever distance fog was on (its ramp is 0 on every miss).
  T is the two multiplied.
- **Lit** (`lit`, 0..1): the colour × the probes' light in the air over the level's average
  (`Probe_Grid.light_mean`: every unburied probe's SH constant band, every layer at full scale, fixed per bake,
  so a light group dimming dims the fog). The colour as picked where the light is average; warmer and brighter
  by a lamp's bounce; darker in a dark corner. Air samples use the visibility test with no normal; where the
  probes can't see the point (under ground, past the grid) it fades to the picked colour, not the dark of
  buried probes. Summed over 6 stretches of the ray weighted by the drop in T across each, offset by the Bayer
  threshold. Subtle outdoors, where the probes hold mostly even sky light.
- **Halos** (`halos`, `glow` per metre; per light `halo`, default 1, on `GPU_Light`): point and spot lights
  scattered toward the eye, haze = `glow` + the height fog's density, × T back to the eye, × the light's
  `halo`, ÷ 4 (isotropic, no 1/π like the surfaces). 12 equiangular steps per light over the ray's chord
  through its range (the angle seen from the light cancels the 1/d²), offset per pixel by the Bayer threshold
  so any stepping is an ordered pattern. `light_reach` gives the same falloff and cone as surfaces.
  Unshadowed: a wall in front cuts a halo (the ray stops there), but a lamp behind a wall lights the air on
  this side within its range. Directional and cylinder lights get none.
- Not built: shadowed halos (shafts: sample the shadow slice at each halo step), fog on blended surfaces at
  their own depth, forward scattering (a Henyey–Greenstein factor per halo step; the SH's directional bands
  for lit fog), analytic fog volumes (boxes, spheres).

### Retro look

Art-directed per level: `World_Settings.retro` (`Retro_Settings`), a plain world setting like fog:
saved as `retro.*` keys, undoable, drawn by the reflection inspector as the Retro Look section of
World Settings. Every effect has its switch and its amounts; there is no master switch in the
settings, the viewport toolbar's retro toggle (`.Retro` / `.Clean`, per view) is the quick on/off. A
view reads the settings of the world it shows (`render_view_retro`): during play that's the play copy,
whose edits go with it at Stop, like every other setting. An effect that's off goes to the shader as 0
and is skipped; `warp` and `dither` are clamped to 0..1 and `color_bits` to 2..8 where they're read.

- Low resolution (`lines`: the whole-number scale closest to it), vertex jitter (grid in scene
  pixels), affine textures (warp), texel lighting, point sampling, colour depth (bits per channel +
  Bayer dither strength).
- **Texel lighting** (`texel_snap`, scene.slang) is a modifier on every shading model, not a model of its
  own: before `shade()`, the pixel's position and normal move to the centre of its colour-texture texel
  (via the UV and position derivatives: exact inside a triangle), so direct light, shadow edges and falloff
  step per texel. The texel is at the sampled mip (coarser far away, no shimmer); snapped with the
  perspective-correct `uv0` even under affine warp; skipped for a solid-colour (1×1) texture and wherever a texel is wider than 32 scene pixels
  (`TEXEL_SNAP_MAX_PIXELS`): a palette-atlas kit (each face in one swatch, like castle's `colormap.png`) gets
  no snap, since its near-zero UV derivatives would light each quad from an arbitrary point. Flat's face
  normal is taken before the snap, since it comes from the position's derivatives. A texel cut by a
  triangle edge is lit from each side's plane (a seam on curved low-poly meshes, accepted).

Passes (`render_post.odin`): signal (scene size: tonemap + quantize/dither) → upscale (display size,
point-sampled). A clean view runs the signal pass alone, straight into the display target.

No CRT emulation (composite blur, scanlines, aperture grille, tube bloom): built once (2026-10) and
removed, the look wasn't wanted. Don't re-add it.

UI renders at native resolution after the upscale; the world renders low-res.

Dynamic objects go through the **same pass and the same post chain** as static geometry,
never a separate composite — the artifacts must apply uniformly or characters read as
pasted on. Only the lighting input differs (probes vs baked), which is a PSO bucket.

| | |
|---|---|
| Safe | baked GI, fog (generously), LUT grading, vertex shader animation, additive particles |
| Careful | bloom (tight, high threshold), hard shadows, mirrored-camera water instead of SSR |
| Avoid | TAA (destroys jitter, pixels, and dither), motion blur, DOF, SSAO, PBR, realtime GI |

No prerendered backgrounds. Realtime geometry with generous bakes gets depth for free, lets
the camera move, lets lighting change, and is authored once.

