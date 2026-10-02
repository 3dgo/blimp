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
  (`tex`) that ImGui samples and screenshots read. `render_post.odin` (`post.slang`, one
  fullscreen pass) resolves one into the other; debug lines draw after it, onto the display
  target, so their colours stay exact.
- **The scene target and depth are the display size ÷ `scene_scale`, rounded up**
  (`dx.Viewport_Options.scene_scale`). The scene VS squeezes NDC by `sceneCover` so the image
  lines up with the display pixel for pixel while the projection stays the display's (CPU
  picking is unaffected). Depth is `R32_TYPELESS` with a DSV and an `R32_FLOAT` SRV: passes at
  the display size can't bind it as a DSV, so debug lines depth-test against it in the shader.
- **Render mode** is per view (`Render_View.mode`, viewport toolbar). `.PS1` (default, and
  always in release): scale = the whole number bringing the height closest to 216, vertices
  snapped to whole scene pixels (`vertexSnap`), affine UVs (`affine` = `PS1_AFFINE`), point
  sampler, dither on. `.Clean`: scale 1, none of the rest. Same shaders and passes; only frame
  constants and the scale differ, so the two can't drift. Affine UVs are a second
  `noperspective` varying blended by `affine`, since interpolation can't switch at runtime.
  Debug lines don't snap, so an outline can sit up to a scene pixel off its jittering mesh.
- **Shading is linear.** Colour textures are `_SRGB` views (decoded on sample); glTF material
  and vertex colours and light `color` are linear (the picker shows light colour as sRGB,
  `widget:linear_color`). The world `background` is display-space (sRGB): the scene target
  clears to it with alpha 0, the scene writes alpha 1, and the tonemap passes alpha-0 pixels
  through untouched, so the background shows exactly as picked.
- Light data lives in a GPU buffer indexed from the shader, not root constants.
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
Mesh_Instance :: struct { transform, mesh, material, flags: u32 }

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
- Separate command buffer + counter per PSO bucket (opaque, alpha-test, shadow). Group
  mesh instances so each bucket is a contiguous range — retrofitting this is painful.
- One command per mesh instance is fine. Batching identical meshes needs sort + compact
  and gives up the root constant. Only if it profiles badly.

### Skinning

- Same shared buffers. Skinning data in a parallel stream with `skin_offset` as a
  sentinel for static meshes; the shader branch is uniform per draw.
- Bone matrices in a per-frame suballocated buffer with `bone_offset` on the instance.
  Double-buffered.
- Vertex skinning, not compute skinning. Apply vertex snapping **after** skinning, in
  clip space.

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
  materials plus tight bloom, separate from the lighting solve.
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
  `Scene_BVH`: top level over a world's mesh instances (entity × mesh, world bounds); a leaf
  sends the ray into its mesh's BVH through the inverse entity transform. Built on demand as a
  snapshot — the baker builds one per bake over `entity_bakes` (drawn, `Static`, `Cast_Indirect`).
  Closest-hit and any-hit (shadow rays) queries, iterative with a fixed stack.
- **Indirect only.** Every light stays realtime direct; a light reaches a probe only off a
  surface it lit. The sky (World Settings `sky_color × sky_intensity`, linear) is in the probes.
- **Grid**: the static geometry's bounds plus one `probe_spacing` all round, at most
  `MAX_PROBES`. Per pass, every probe casts 256 rays on a **Fibonacci sphere** (the same set
  everywhere, so a bake repeats exactly). Miss → sky. Front-face hit → `albedo × (direct + previous
  pass's grid sampled there)`; direct is the scene shader's diffuse with one shadow ray per light
  that reaches the point, shadowed whatever the light's `shadow` says. Back-face hit → black, and
  counted (a probe with > 25% is "buried"). Three passes = three bounces.
- **Projection**: Monte Carlo `c_i += L·Y_i·4π/N`, convolved with the cosine lobe and **divided by
  π**, so the shader's indirect is `albedo × max(0, sh_eval(N))` — the same no-1/π convention as
  direct, so what's lit on screen is exactly what bounces.
- Front faces: `cross(v1 − v0, v2 − v0)` points out (clockwise front, left-handed).
- **Threads**: each pass is a `parallel_for` (`basics.odin`) over probes on every core: `core:thread`
  workers claim chunks off one atomic counter; each probe writes only its own slot, and the body
  never allocates or logs.
- **Albedo**: `asset_system.material_albedo`, computed at load, kept beside `Material` (whose
  layout is the GPU's).
- **Storage**: the level's binary sidecar `foo.level` → `foo.probes` (version 2: header with the layer → light-group map, then each layer's `Probe_SH`),
  written by the bake and read by `scene_load`. A bake is **not an edit**: no undo step, nothing
  unsaved. The grid has its own arena (`Probe_Grid.arena`), freed whole on rebake. A play world
  lights with its level's grid. The GPU copy is one buffer per world, replaced after
  `renderer_dx_wait_idle`, so bakes run outside the frame (UI or remote).
- **Shader**: `Probe { float c[27]; float _pad; }` (112 B, a float array so structured-buffer
  layout can't differ from Odin), manual 8-tap trilinear (`probe_irradiance`) — manual so the
  Chebyshev weight can fold into each corner. No grid → flat `AMBIENT`.
- Settings are `World_Settings.bake` (saved as `bake.*` keys in `[world]`), edited in the **Probe Bake
  window** (`ui_bake.odin`, its own toolbar button): settings, Bake, last-bake stats, and the **probe
  atlas** — a picture of the grid, not lighting data: each probe an 8×8 octahedral tile of `sh_eval`
  (centre up), one block per layer seen from above, at the exposure it was baked with; hover names
  the probe, outlines its tile and draws a yellow square on it in the world's views; double-click frames it. Built on the CPU with the grid (`probe_grid_atlas`), shown through an ImGui-heap SRV.
- Debug views, per view from the toolbar's **Lighting** menu (`Render_View.lighting`, `probes_off`,
  `indirect_scale`, all frame constants): Lit, Probes Only (probe light on white), Indirect Only,
  Direct Only, Lighting Only (white albedo); baked probes vs the flat ambient; an indirect multiplier;
  Show Probes (six spokes per probe coloured by `sh_eval` along ±X/±Y/±Z). blimpctl `bake` / `probe`.
- Build order: BVH and tracer → uniform grid with naive interpolation → **observe the
  leaking** → add the visibility test. Don't add the fix before seeing the problem. **Done up to
  naive interpolation.** Next, in order: buried probes get weight 0; octahedral depth + Chebyshev;
  per-mesh AO.

### Shadows

- **Hard, low-res, unfiltered.** 512² or 256², point sampled. Soft PCF edges read as modern
  and break the look.
- Point lights use cube maps (6 faces). Cascades are a directional-light technique; 2–3
  cascades for exteriors if needed.
- **Cache static shadow maps**, re-render only when something dynamic enters range. Biggest
  available win in this design. **Not done yet**: every slice redraws every frame.
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

