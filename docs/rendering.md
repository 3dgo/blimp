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
  (`tex`) that ImGui samples and screenshots read. `render_post.odin` resolves one into the
  other; debug lines draw after it, onto the display target, so their colours stay exact.
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
- Only two or three genuinely-moving realtime lights. A baked fire's intensity can be
  modulated at runtime and reads as flickering.

### Baker

CPU tracer. Not DXR, not GPU hemicube — baking is offline, so a breakpoint on a bad texel
is worth more than a 100× speedup.

- Median-split BVH plus ray-triangle intersection. The BVH is reusable for physics queries,
  editor picking, and occlusion.
- Per sample point: N cosine-weighted rays over the hemisphere → BVH query → sky color on
  miss, surface radiance on hit → average. Direct light separately: one shadow ray per
  light, scaled by `max(0, dot(N, L))`.
- Build order: BVH and tracer → uniform grid with naive interpolation → **observe the
  leaking** → add the visibility test. Don't add the fix before seeing the problem.

### Shadows

- **Hard, low-res, unfiltered.** 512² or 256², point sampled. Soft PCF edges read as modern
  and break the look.
- Point lights use cube maps (6 faces). Cascades are a directional-light technique; 2–3
  cascades for exteriors if needed.
- **Cache static shadow maps**, re-render only when something dynamic enters range. Biggest
  available win in this design.
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

