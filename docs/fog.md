# Building fog, step by step

A guide to rebuilding the fog we had, one working stage at a time. Each step ends with something you can
see and check before going on. The final stage has:

- **Distance fog**: the PS1 ramp between a start and an end distance, in its own colour.
- **Height fog**: exponential ground mist, in its own colour.
- **Lit fog**: both colours brightened, darkened and tinted by the baked probe light in the air.
- **Lamp halos**: point and spot lights glowing in the fog, with a per-light Halo Intensity.

All of it is **analytic**, worked out exactly per pixel instead of ray-marched through a grid. It needs no
history buffer, so it has no temporal smearing and reacts to changes on the very next frame.

Each step lists what you'll learn, where the code goes, the idea, and how to check it. The reference code
sits in collapsed blocks: try it yourself first and open them when you're stuck.

---

## Step 0: How a setting reaches a pixel

Every fog feature follows the same path through the engine. It's worth tracing once before writing anything.

```
World_Settings (world.odin)          a field here gets the World Settings inspector and the
        │                            [world] keys in the .level file for free (reflection)
        ▼
render_view_update_constants         runs per view per frame and fills Frame_Constants
(render_view.odin)
        │
        ▼
Frame_Constants (render_dx.odin)  ══ the same layout ══  FrameConstants (common.slang)
        │                                                        │
        ▼                                                        ▼
mapped into the view's constant buffer                  gFrame.* in every shader
        │
        ▼
post.slang: frag_signal              the "signal" pass: one fullscreen triangle at scene resolution
                                     (384×216 in retro) that does HDR → tonemap → quantize + dither
```

Things to read first:

- **`frag_signal` in `post.slang`.** Your fog goes in here. Note the order: exposure → `aces_fitted` →
  `linear_to_srgb` → `quantize_dither`. Fog must come **before** the quantize so it gets dithered like
  everything else.
- **The `#assert`s under `Frame_Constants` in `render_dx.odin`.** HLSL packs a constant buffer in 16-byte rows:
  a `vec3` may not straddle a row, and a matrix must start on one. Odin has no attribute for that, so every
  vector field gets an assert. **Every field you add to `Frame_Constants` must be added at the same place in
  `FrameConstants` in `common.slang`.**
- **How the depth buffer is stored:** reversed-Z, so 1 = near plane and 0 = far (cleared to 0). The editor
  camera's projection is infinite (`perspective_projection_reverse_z`): depth 0 really is infinitely far.
- **The background, today:** alpha 0 in the HDR target means "nothing was drawn here". It holds the
  world's background colour in display space (sRGB) and skips the tonemap. Step 2 removes that exception.

**How to check your work** (CLAUDE.md lists the cheapest checks):

```
blimpctl settings 0 fog.on true          # one field per call
blimpctl screenshot 1 out.png
blimpctl timings                         # the GPU time of "view 1"
blimpctl log 20 warn                     # shader compile errors show up here (shaders hot-reload)
```

---

## Step 1: Distance fog in display space

**You'll learn:** adding a world setting, the constant-buffer path, turning depth into a distance.

**Files:** `world.odin`, `loc.odin`, `render_dx.odin`, `common.slang`, `render_view.odin`, `post.slang`.

**The idea:** for each pixel, find how far away it is. Blend toward the background colour by
`saturate((dist − start) / (end − start))`. Do it *after* the tonemap, in display space, so a fully fogged
pixel is exactly the background colour.

Getting the distance:

1. Read the depth at the pixel.
2. Build NDC from the pixel position. The retro view renders into part of a bigger target (`sceneCover`),
   and the scene vertex shader squeezed NDC to fit, so undo that.
3. Multiply `float4(ndc, depth, 1)` by the **inverse projection** to get the view-space position. Its length
   is the distance from the eye.
4. The inverse must be of the matrix the view actually rendered with. In game mode that's the camera
   entity's, so compute it *after* the camera-entity override in `render_view_update_constants`.

**Check:** turn fog on with a short end distance. Far things should melt into the background colour.

<details><summary>Reference code</summary>

`world.odin`, a field in `World_Settings`, the struct, and the default in `WORLD_SETTINGS_DEFAULT`:

```odin
fog: Fog_Settings `loc:World_Fog`,   // distance fog into the background colour

Fog_Settings :: struct {
    on:    bool `loc:World_Fog_On`,
    start: f32  `loc:World_Fog_Start`,   // full colour nearer than this
    end:   f32  `loc:World_Fog_End`,     // all background colour from here on
}

fog = {start = 20, end = 60},
```

`loc.odin`: add `World_Fog, World_Fog_On, World_Fog_Start, World_Fog_End` to the enum, and the rows:

```odin
.World_Fog       = { .EN = "Fog",       .ZH = "雾" },
.World_Fog_On    = { .EN = "On",        .ZH = "开启" },
.World_Fog_Start = { .EN = "Start (m)", .ZH = "起始距离（米）" },
.World_Fog_End   = { .EN = "End (m)",   .ZH = "结束距离（米）" },
```

`render_dx.odin`, between `brightness` and `skin_buffer_slot`:

```odin
fog_color:    vec3,  // the background, display space
fog_start:    f32,
fog_end:      f32,   // <= fog_start: fog off
_pad_fog:     [2]f32,
inv_proj:     mat4,  // the projection this view rendered with, inverted
```

Then `_padding: [512 - 472]byte`, the `_padding` offset assert becomes 472, and two new asserts:

```odin
#assert(offset_of(Frame_Constants, fog_color) % 16 + size_of(vec3) <= 16)
#assert(offset_of(Frame_Constants, inv_proj) % 16 == 0)
```

`common.slang`, at the same place:

```slang
public float3   fogColor;
public float    fogStart;
public float    fogEnd;
public float2   _padFog;
public float4x4 invProj;
```

`render_view.odin`, after the camera-entity block (add `import "core:math/linalg"`):

```odin
frame_constants.inv_proj = linalg.inverse(frame_constants.proj_mat)
if fog := world.settings.fog; fog.on && fog.end > fog.start {
    frame_constants.fog_color = world.settings.background
    frame_constants.fog_start, frame_constants.fog_end = fog.start, fog.end
}
```

`post.slang`:

```slang
float fog_amount(uint2 px) {
    Texture2D<float> depthTex = getTexture2dF1(gFrame.depthTextureSlot);
    uint w, h;
    depthTex.GetDimensions(w, h);
    float depth = depthTex.Load(int3(px, 0));
    float2 uv = (float2(px) + 0.5) / float2(w, h);
    float2 ndc = float2(uv.x * 2 - 1, 1 - uv.y * 2);
    float2 cover = gFrame.sceneCover;
    ndc = float2((ndc.x - (cover.x - 1)) / cover.x, (ndc.y - (1 - cover.y)) / cover.y);
    float4 v = mul(float4(ndc, depth, 1), gFrame.invProj);
    float dist = length(v.xyz / v.w);
    return saturate((dist - gFrame.fogStart) / (gFrame.fogEnd - gFrame.fogStart));
}

// in frag_signal, after the tonemap and before the quantize:
if (gFrame.fogEnd > gFrame.fogStart) c = lerp(c, gFrame.fogColor, fog_amount(px));
```

</details>

---

## Step 2: One pipe: the fog and the background go through the tonemap

**You'll learn:** the difference between "scene light" and "display colour", and why the engine decided
against exceptions to the tonemap (claude/rendering.md, under "Shading is linear").

**Why:** Step 1 blends after the tonemap, toward a display colour. Halos and lit fog (later steps) are
*light*: they have to be added in linear HDR before the tonemap, or they'd ignore exposure and clip wrongly.
So the fog moves before the tonemap:

```
light = scene × T + fogColor × (1 − T)        then exposure → tonemap → quantize
```

Here T is the **transmittance**: how much of the surface gets through (1 = clear, 0 = all fog).

**The decision (option B):** every pixel goes through the same pipe, with no exceptions. So:

1. **Fog colours are linear scene light.** Tag them `widget:linear_color`, like light colours: the picker
   shows sRGB but stores linear. Send them to the shader as they are.
2. **The background becomes linear too.**
   - Change `background` in `World_Settings` to `widget:linear_color`, and fix its comment and the one on
     `render_view_clear_color`.
   - Delete `if (s.a == 0) return float4(s.rgb, 1);` in `frag_signal`. Only that line reads the clear alpha
     today.
   - The background now gets exposure, the tonemap and the dither like everything else.
3. **"Nothing drawn" now comes from the depth instead:** depth 0 (reversed-Z clear) = the ray never hit
   anything. Step 3 uses that for the ray length.

What you give up: a picked colour no longer shows exactly as picked, because ACES shifts it (a mid grey 0.5
shows as about 0.4) and exposure scales it. You judge sky and fog colours in the engine. What you get: no
special cases anywhere, and the fogged background and fully fogged geometry come out identical automatically.

**Existing levels:** the castle's `background` was picked as sRGB. Read as linear it will look different, so
re-pick it once after this step.

**Check:** fog everything (start 0, end 0.5), switch the view to clean (`blimpctl retro 1 off`), take a
screenshot and count the distinct colours. You should get exactly one: background and geometry are both
fully fog. It won't be the exact picked value, because of the tonemap, and that's expected now.

*(Not taken: option A, which runs the tonemap backwards so a picked colour shows exactly. That costs an
inverse ACES on the CPU for picked colours, and per pixel for a painted sky.)*

---

## Step 3: A world-space ray per pixel

**You'll learn:** unprojecting, and inverting a rigid view matrix cheaply.

**Why:** height fog depends on world height, and halos depend on where the lights are. So each pixel needs
a ray in **world space**, not just a distance:

- **origin:** the near-plane point (depth = 1 in reversed-Z), unprojected;
- **direction:** toward a point a little further in (depth 0.5), normalized. This works for perspective and
  ortho cameras alike;
- **length:** to the scene depth. Where the depth is 0 (nothing drawn: the background), use a large stand-in
  for infinity (1e6), because with an infinite projection, depth 0 would divide by zero. Blended surfaces
  don't write depth, so a pixel covered only by one also counts as infinitely far. That's the fog of what's
  behind it, which is how blended surfaces are fogged anyway.

View space to world space: the view matrix is rigid (rotation + translation). With the engine's row-vector
convention (`mul(pos, viewMat)`), a world direction is `mul(R, v)`, where `R` is the matrix's upper 3×3.
A world point is `cameraPos + mul(R, v)`.

<details><summary>Reference code</summary>

```slang
static const float FOG_INFINITY = 1e6;   // the background's ray length, metres

struct FogRay {
    float3 origin;   // world space, on the near plane
    float3 dir;
    float  len;      // metres to the scene surface; FOG_INFINITY for the background
}

float3 view_pos(float2 ndc, float depth) {
    float4 v = mul(float4(ndc, depth, 1), gFrame.invProj);
    return v.xyz / v.w;
}

// The view matrix is rigid, so its inverse rotation is its transpose.
float3 world_dir(float3 v) {
    float3x3 R = float3x3(gFrame.viewMat[0].xyz, gFrame.viewMat[1].xyz, gFrame.viewMat[2].xyz);
    return mul(R, v);
}

FogRay fog_ray(uint2 px) {
    Texture2D<float> depthTex = getTexture2dF1(gFrame.depthTextureSlot);
    uint w, h;
    depthTex.GetDimensions(w, h);
    float2 uv = (float2(px) + 0.5) / float2(w, h);
    float2 ndc = float2(uv.x * 2 - 1, 1 - uv.y * 2);
    float2 cover = gFrame.sceneCover;
    ndc = float2((ndc.x - (cover.x - 1)) / cover.x, (ndc.y - (1 - cover.y)) / cover.y);
    float3 nearV = view_pos(ndc, 1);   // reversed-Z: 1 is the near plane
    FogRay r;
    r.origin = gFrame.cameraPos + world_dir(nearV);
    r.dir    = normalize(world_dir(view_pos(ndc, 0.5) - nearV));
    float depth = depthTex.Load(int3(px, 0));
    r.len    = depth == 0 ? FOG_INFINITY : length(view_pos(ndc, depth) - nearV);   // 0: nothing drawn
    return r;
}
```

</details>

---

## Step 4: Height fog

**You'll learn:** optical depth, Beer–Lambert, and doing an integral in closed form instead of marching.

**The idea:**

- **Density** (fog per metre) falls off exponentially with height: `σ(y) = density · e^(−(y − height) / falloff)`.
- **Transmittance** along a ray is `T = e^(−τ)`, where the **optical depth** τ is the density added up along
  the ray.
- Along a ray, `y = origin.y + dir.y · t`, so τ is the integral of an exponential, which has a closed form:

```
τ(t) = σ(origin.y) · t · (1 − e^(−x)) / x,      x = dir.y · t / falloff
```

When x ≈ 0 (a level ray), use the limit `1 − x/2`. The total transmittance is distance T × height T.

**Lesson learned the hard way:** a background ray pointing *down* never ends, so τ grows without bound and
overflows to infinity. Later, the colour mix (step 5) divides by τ, and ∞/∞ = NaN, which shows as a black
void below the horizon. Two fixes:

1. Clamp x from below (−80), and clamp `t · s` before multiplying by the density.
2. Cap τ at a "fully opaque" value of 100 (e^−100 is 0 anyway).

**Check:** put the camera above the ground. The mist should be thick in valleys and thin out going up, and
the void below the horizon should be mist-coloured, not black.

<details><summary>Reference code</summary>

```slang
static const float FOG_OPAQUE = 100;   // optical depth: nothing gets through (e^-100)

float fog_height_density(float y) {
    if (gFrame.fogDensity <= 0) return 0;
    return gFrame.fogDensity * exp(clamp((gFrame.fogHeight - y) / gFrame.fogFalloff, -80, 80));
}

float fog_height_depth(FogRay r, float t) {
    if (gFrame.fogDensity <= 0) return 0;
    float x = max(r.dir.y * t / gFrame.fogFalloff, -80);
    float s = abs(x) > 1e-4 ? (1 - exp(-x)) / x : 1 - 0.5 * x;
    return min(fog_height_density(r.origin.y) * min(t * s, 1e30), FOG_OPAQUE);
}

float fog_distance_transmittance(float t) {
    if (gFrame.fogEnd <= gFrame.fogStart) return 1;
    return 1 - saturate((t - gFrame.fogStart) / (gFrame.fogEnd - gFrame.fogStart));
}

float fog_transmittance(FogRay r, float t) {
    return fog_distance_transmittance(t) * exp(-fog_height_depth(r, t));
}
```

The settings: `height_fog: bool`, `height`, `density` (per metre at `height`), and `falloff` (metres up for
the density to fall by e). Send `density = 0` to the shader when height fog is off; the shader treats that
as off.

</details>

---

## Step 5: A colour for each fog

**You'll learn:** mixing two media.

**The idea:** each fog has its own linear colour (step 2). Where both overlap, mix the colours by **each one's
share of the optical depth**, so the thicker one along this ray shows more. The distance ramp isn't a
density, but it has an equivalent optical depth: `τ_d = −ln(T_d)` (clamp T_d ≥ 1e-6 first).

```
color   = (τ_d · C_distance + τ_h · C_height) / (τ_d + τ_h)
fog     = color × (1 − T)
pixel   = scene × T + fog           (the background too: its scene light is the clear colour)
```

Since step 2, the background is just a pixel whose ray never hit anything, so it needs no special case.

**Check:** with distance fog only, the sky becomes the distance colour (the fog is fully opaque at `end`). With
height fog only, the sky above the horizon stays the background colour.

<details><summary>Reference code</summary>

```slang
bool fog_on() {
    return gFrame.fogEnd > gFrame.fogStart || gFrame.fogDensity > 0 || gFrame.fogGlow > 0;
}

[shader("fragment")]
float4 frag_signal(VSOut input) : SV_Target {
    Texture2D<float4> hdr = getTexture2dRGBA(gFrame.hdrTextureSlot);
    uint2 px = uint2(input.position.xy);
    float3 light = max(hdr.Load(int3(px, 0)).rgb, 0);
    if (fog_on()) {
        FogRay r = fog_ray(px);
        float T;
        float3 add = fog_inscatter(r, px, T) + fog_halos(r, px);   // fog_halos: step 6
        light = light * T + add;
    }
    float3 c = linear_to_srgb(aces_fitted(light * gFrame.exposure));
    if (gFrame.colorLevels > 0) c = quantize_dither(c, px);
    return float4(c, 1);
}
```

`fog_inscatter`, without lit fog (step 7 extends it):

```slang
float3 fog_inscatter(FogRay r, uint2 px, out float T) {
    float distanceT = fog_distance_transmittance(r.len);
    float heightDepth = fog_height_depth(r, r.len);
    T = distanceT * exp(-heightDepth);
    if (T == 1) return 0;
    float distanceDepth = -log(max(distanceT, 1e-6));
    float3 color = (distanceDepth * gFrame.fogDistanceColor + heightDepth * gFrame.fogHeightColor)
                 / (distanceDepth + heightDepth);
    return color * (1 - T);
}
```

On the CPU, send each fog's settings only when it's on. Leave the rest of the fields zero, which the shader
treats as "off".

</details>

---

## Step 6: Lamp halos, with a per-light intensity

**You'll learn:** single scattering from a point light, equiangular sampling, adding an entity field
through the schema, and GPU struct padding.

**The idea:** each point or spot light scatters light toward the eye from the air it passes through. Along
the ray, add up:

```
light reaching the point (light_reach: the same falloff and cone as surfaces)
× haze there (glow + height fog density) × T back to the eye × the light's halo ÷ 4
```

The ÷ 4 is isotropic scattering, 1/4π, times π, because the engine's lights carry no 1/π.

**Equiangular steps** (Kulla & Fajardo 2012): the light falls off as 1/d², which peaks sharply where the ray
passes the bulb. Evenly spaced steps along the ray would miss that peak. Step evenly in the **angle seen from
the light** instead:

1. Find the closest approach `t0` and the closest distance `h`.
2. Substitute `t = t0 + h·tan θ`. Then `dt = (h² + s²)/h dθ`, and the `h² + s²` cancels the 1/d².
3. Only integrate over the part of the ray inside the light's range: the chord through a sphere of radius
   `range`, clipped to `[0, len]`.
4. Use `h = max(h, innerRadius, 0.01)` for the step scale, so the steps don't bunch up when the ray goes
   through the bulb.
5. 12 steps per light is enough. Offset them per pixel by the Bayer threshold, so any leftover stepping
   becomes an ordered pattern like the dither.

To call `light_reach` and `view_direct` from `post.slang`, make them `public` in `shading.slang` and
`import "shading";` in `post.slang`.

**The per-light Halo Intensity** is your first entity field:

1. Add it to `entity_schema.ini`. The build's codegen writes `src/gen_entity.odin`, so don't hand-edit that.
2. Add `halo` to `GPU_Light` in `render_buffers.odin`. The struct was exactly 80 bytes (5 rows), so one
   float plus 3 padding floats makes it 96. Update its size assert.
3. Add the same field and padding to `Light` in `common.slang`.
4. Fill it in `entity_gpu_light`.

**Limitation:** no shadows. A wall in front of a lamp cuts its halo off, because the ray stops at the wall.
But a lamp behind a wall still lights the air on your side, within its range.

**Check:** turn on halos with no mist (glow only). Torches should glow, and their halos should end at walls in
front of them. A light with Halo Intensity 0 should show no glow.

<details><summary>Reference code</summary>

`entity_schema.ini` (after `[field.indirect]`):

```ini
[field.halo]
type    = f32
builtin = true
section = Camera_Light
en      = Halo Intensity
zh      = 光晕强度
default = 1
note    = Point / spot light: scales the glow it makes in the fog, without touching its light on surfaces. 0 = no halo.
```

`render_buffers.odin`:

```odin
    shadow_texel: f32,
    halo: f32,                         // × its glow in the fog (post.slang fog_halos)
    _pad: [3]f32,
}
#assert(size_of(GPU_Light) == 96)

// in entity_gpu_light:
halo = max(entity.halo, 0),
```

`common.slang`, at the end of `Light`:

```slang
public float halo; public float _pad0; public float _pad1; public float _pad2;
```

`post.slang`:

```slang
static const uint HALO_STEPS = 12;

float3 fog_halos(FogRay r, uint2 px) {
    if (gFrame.fogGlow <= 0 || !view_direct()) return 0;
    StructuredBuffer<Light> lights = DescriptorHandle<StructuredBuffer<Light>>(gFrame.lightBufferSlot);
    float offset = BAYER_4X4[(px.y & 3) * 4 + (px.x & 3)];
    float3 sum = 0;
    for (uint i = 0; i < gFrame.lightCount; i++) {
        Light light = lights[i];
        if ((light.type != LIGHT_POINT && light.type != LIGHT_SPOT) || light.halo <= 0) continue;
        float3 toLight = light.position - r.origin;
        float  t0 = dot(toLight, r.dir);            // the ray's closest approach to the light
        float  h  = length(toLight - r.dir * t0);   // and how close
        if (h >= light.radius) continue;
        float  c = sqrt(light.radius * light.radius - h * h);
        float  a = max(t0 - c, 0), b = min(t0 + c, r.len);
        if (a >= b) continue;
        float  hs  = max(h, max(light.innerRadius, 0.01));
        float  thA = atan((a - t0) / hs), thB = atan((b - t0) / hs);
        float  acc = 0;
        for (uint k = 0; k < HALO_STEPS; k++) {
            float  s = hs * tan(lerp(thA, thB, (k + offset) / HALO_STEPS));
            float3 p = r.origin + r.dir * (t0 + s);
            float3 L;
            float  haze = gFrame.fogGlow + fog_height_density(p.y);
            acc += light_reach(light, p, L) * (hs * hs + s * s) * haze * fog_transmittance(r, t0 + s);
        }
        sum += light.color * light.intensity * light.halo * acc * (thB - thA) / (HALO_STEPS * hs);
    }
    return sum * 0.25;
}
```

World settings: `halos: bool` and `glow: f32` (haze per metre, so halos show with no mist; default 0.05).

</details>

---

## Step 7: Fog lit by the probes

**You'll learn:** spherical harmonics, the probe grid and its visibility test, and doing the expensive part
once on the CPU.

**The idea:** keep your picked colours, and scale them by the **baked light in the air** compared with the
**level's average** baked light. Average-lit places keep exactly your colour, the air near a lamp's bounce
light gets warmer and brighter, and dark corners get darker. A `lit` amount from 0 to 1 blends from flat to
fully lit.

- **Light in the air:** each probe stores L2 SH of irradiance/π. Convolving with the cosine lobe leaves
  band 0 unchanged, so the **constant band** (`0.282095 · c[0]`) is the probe's light averaged over every
  direction, which is what fog scattering equally in all directions sees.
- **Sampling between probes:** reuse `probe_irradiance`'s trilinear-plus-visibility code with N = 0, which
  means "a point in the air": no normal offset, and the backface term becomes a constant 0.45. Return the
  corners' **total weight** too. Divided by 0.45, that weight says how well the probes see this point.
  Under the ground, inside walls or outside the grid, it drops toward 0. Fade the scale back to 1 (your plain
  colour) there, instead of taking the black of buried probes.
- **Level average (CPU, once):** in `probe_grid_set`, average the constant band over every probe that isn't
  buried, with all layers at full scale. A buried probe has an all-zero depth map. Keep the average on
  `Probe_Grid`. Because it's fixed per bake, a light group dimming at runtime dims the fog around it.
- **Along the ray:** the light changes along the ray, so split the foggy part into 6 stretches. That's from
  where the fog starts to `fogEnd`, or 64 m for height fog alone. Weight each stretch's light by the fog it
  holds, the drop in T across it. The fog beyond takes the last stretch's light. Offset the sample points by
  the Bayer threshold.
- **The constant buffer grows:** these fields push `Frame_Constants` past 512 bytes, so it goes to 768.
  Constant buffers come in 256-byte steps.

**Check:** compare `lit 0` with `lit 1`. Outdoors the difference is small, because the probes hold mostly
even sky light. It's meant for lamp-lit interiors. Switching a light group off should darken the fog near
those lights.

<details><summary>Reference code</summary>

`shading.slang`:

```slang
// The SH's constant band: the probe's light averaged over every direction.
float3 sh_mean(Probe p) {
    return 0.282095 * float3(p.c[0], p.c[1], p.c[2]);
}

// probe_irradiance becomes probe_grid with an out weight; N = 0 is a point in the air:
float3 probe_grid(float3 pos, float3 N, out float weight) {
    // ... as probe_irradiance, plus:
    bool air = all(N == 0);
    // ... in the layer loop:
    //     if (scale == 0) continue;
    //     Probe p = probes[k * count + index];
    //     e += w * scale * (air ? sh_mean(p) : sh_eval(p, N));
    // ... after the corner loop:
    weight = total;
    return max(e / max(total, 1e-6), 0);
}

float3 probe_irradiance(float3 pos, float3 N) {
    float weight;
    return probe_grid(pos, N, weight);
}

public float3 air_light(float3 pos, out float seen) {
    float3 e = probe_grid(pos, 0, seen);
    seen = saturate(seen / 0.45);   // probe_visibility's backface term with no normal
    return e;
}
```

`world_probes.odin` (`light_mean: vec3` on `Probe_Grid`, set in `probe_grid_set` after the depth copy):

```odin
probe_light_mean :: proc(g: ^Probe_Grid) -> vec3 {
    count := probe_count(g)
    sum: vec3
    n := 0
    probes: for i in 0 ..< count {
        buried := true
        for t in g.depth[i].t do if t[0] > 0 { buried = false; break }
        if buried do continue probes
        for k in 0 ..< int(g.layers) do sum += 0.282095 * g.probes[k * count + i].c[0]
        n += 1
    }
    return n > 0 ? sum / f32(n) : {}
}
```

`post.slang`:

```slang
static const float FOG_LIT_REACH = 64;
static const uint  FOG_LIT_STEPS = 6;

float3 fog_lit_scale(float3 p) {
    float seen;
    float3 light = air_light(p, seen);
    return lerp(1, light / max(gFrame.fogLightMean, 1e-4), seen);
}

// in fog_inscatter, replacing `return color * (1 - T);`:
if (gFrame.fogLit <= 0) return color * (1 - T);
bool  distance = gFrame.fogEnd > gFrame.fogStart;
float a = gFrame.fogDensity > 0 || !distance ? 0 : gFrame.fogStart;
float b = min(r.len, distance ? gFrame.fogEnd : FOG_LIT_REACH);
float offset = BAYER_4X4[(px.y & 3) * 4 + (px.x & 3)];
float prev = fog_transmittance(r, a);
float3 lit = 0, scale = 1;
for (uint k = 0; k < FOG_LIT_STEPS; k++) {
    float Tk = fog_transmittance(r, lerp(a, b, float(k + 1) / FOG_LIT_STEPS));
    scale = fog_lit_scale(r.origin + r.dir * lerp(a, b, (k + offset) / FOG_LIT_STEPS));
    lit += (prev - Tk) * scale;
    prev = Tk;
}
lit += (prev - T) * scale;
return color * lerp(1 - T, lit, gFrame.fogLit);
```

On the CPU, send `fog_lit` and `fog_light_mean` only when the view has probes (`fc.probe_dims.x > 0`) and
the mean isn't zero.

</details>

---

## The final layout, for reference

`Fog_Settings`, as the inspector shows it:

| Field | Meaning |
|---|---|
| `on`, `start`, `end`, `color` | distance fog: the ramp, and its colour (linear, `widget:linear_color`) |
| `height_fog`, `height`, `density`, `falloff`, `height_color` | height fog (its colour linear too) |
| `lit` | 0..1: how far both colours follow the probes' light |
| `halos`, `glow` | lamp halos, and the haze per metre that shows them with no mist |

Fog fields in `Frame_Constants`, inserted between `brightness` (which ends at offset 372) and
`skin_buffer_slot`, then continued after `bone_buffer_slot`. These are the offsets we had working:

| Offset | Field | |
|---|---|---|
| 372 | `background_light: vec3` | the background as scene light |
| 384 | `fog_start`, `fog_end`, `fog_height`, `fog_density` | |
| 400 | `inv_proj: mat4` | |
| 464 | `skin_buffer_slot`, `bone_buffer_slot` | (existing) |
| 472 | `fog_falloff`, `fog_glow` | |
| 480 | `fog_distance_color: vec3`, `fog_lit` | |
| 496 | `fog_height_color: vec3`, `_pad_fog` | |
| 512 | `fog_light_mean: vec3` | |
| 524 | `_padding: [768 − 524]byte` | |

The cost at the end, with everything on, was about 0.38 ms for the castle view on the GPU (0.21 ms
without fog).

---

## Where to go next

These are ideas we discussed, none of them built:

- **Shadowed halos (light shafts):** sample the light's shadow slice at each of the 12 halo steps
  (`shadow_visibility` in `shading.slang`), for lights with Cast Shadow. You get beams through windows, still
  with no temporal artefacts.
- **Fog on blended surfaces:** they don't write depth, so they take the fog of what's behind them. A torch
  sprite in front of a far wall gets the wall's heavy fog. Evaluate the fog in the blended scene shader at the
  surface's own distance instead.
- **Forward scattering:** real fog glows brighter looking toward a light. Multiply each halo step by a
  Henyey–Greenstein phase factor. For lit fog, the same idea uses the SH's directional bands, so the fog
  glows toward a bright window or the sky.
- **Fog volumes:** boxes or spheres of fog placed as entities. Ray–box and ray–sphere intersections are
  closed form, so they fit the analytic approach.
- **What ray marching would add on top:** arbitrary or noisy density, and volumetric clouds. Froxel fog
  costs you temporal smearing and lag, which this design avoids.
