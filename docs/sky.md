# Building the sky, step by step

A guide to replacing the flat background colour with a painted sky: a panorama texture drawn by its own small
shader, behind everything, in every view. Each step ends with something you can see or check before going on.
The final stage has:

- **A sky panorama**: an equirectangular PNG from `assets/skies/`, picked per world in World Settings → Sky,
  with an intensity and a rotation.
- **One pass, before the opaques**: a fullscreen triangle into the scene target. Fog, exposure, the tonemap
  and the dither all apply to it, because it's scene light like every other pixel.
- **Optionally, a sky that lights the probes**: a bake ray that misses takes the panorama's colour in its
  direction instead of the flat sky colour.

Each step lists what you'll learn, where the code goes, the idea, and how to check it. The reference code sits
in collapsed blocks: try it yourself first, and open them when you're stuck. All of it was built and checked
in a copy of the engine before this guide was written.

---

## Step 0: The design, and why

**What a sky is here.** A sky is infinitely far away, so only the **direction** of a pixel's ray matters, never
its position. "Draw the sky" means: for every pixel, find the world direction through it, then look that
direction up in a texture.

**Which texture layout: equirectangular (lat-long).** One 2:1 image. Across is the angle around the vertical
(360°), down is the angle from straight up to straight down (180°). It's one PNG you can paint in any tool,
and the existing PNG loader reads it. A cubemap would need six faces, a new texture type and a new loader,
to save a little stretching at the poles you'll rarely look at.

**No HDR.** An 8-bit sRGB PNG × an intensity is enough. HDR skies exist for the sun, which is thousands of times
brighter than the sky beside it and clips in 8 bits. Here the sun is a directional light entity with its own
direct light and shadows, and shading is Lambert with no reflections. The sky only adds soft fill light.

**Where it draws: a fullscreen pass before the opaques.** `claude/rendering.md` already settled this ("Shading
is linear"): a sky mesh would fight the baker's bounds and misses, the shadow pass and the far plane. One
fullscreen triangle into the HDR scene target, drawn right after the clear:

```
render_view_draw (render_view.odin)
    clear colour + clear depth (0 = far)
    ► sky.slang: fullscreen triangle, no depth test, no depth write      ← new
    opaque, cutout, alpha, additive draws (they cover the sky where they draw)
render_post_draw
    frag_signal: fog → exposure → ACES → quantize + dither               (the sky goes through all of it)
```

Because the sky doesn't write depth, its pixels keep the clear's depth 0. The fog in `post.slang` already treats
depth 0 as a ray that hit nothing (length `VIEW_RAY_MISS`), so the sky is fogged like the background was, with
no special case. Distance fog's `fog.max_opacity` decides how much of it shows through; height fog fades it
toward the horizon and leaves the top clear.

**Why not draw it after the opaques, only where depth is still 0?** That saves overdraw, but at 384×216 the
whole sky costs almost nothing. Drawing it first is simpler: no depth test, one state.

**The pieces, in order:**

| Step | What | Files |
|---|---|---|
| 1 | load panoramas from `assets/skies/` | `asset_system.odin` |
| 2 | the `sky` world setting | `world.odin`, `loc.odin`, `world_scene.odin`, `app_remote.odin` |
| 3 | sky fields in the frame constants | `render_dx.odin`, `common.slang`, `render_view.odin` |
| 4 | the sky shader | `sky.slang` (new), `view.slang` |
| 5 | its pipeline, and drawing it | `render_dx.odin`, `render_view.odin` |
| 6 | (optional) the sky lights the bake | `editor_bake.odin` |
| 7 | the docs | `claude/rendering.md` |

---

## Step 1: Load panoramas

**You'll learn:** how the asset system finds textures, and why a sky needs a change to it.

**Files:** `asset_system.odin`.

**The idea:** textures used to load only through glTFs: `asset_system_load` walked the glTF files, and each glTF
imported the images it references. Nothing references a sky, so **every PNG under `assets/` and `assets_engine/`
now loads at init**, keyed by its project path (`assets/skies/dusk.png`), like any other asset key. Load the
PNGs **before** the glTFs: a glTF looks an external image up by key before decoding it, so it then reuses the
one already loaded. `asset_system_import_png_image` already does the decoding and keying. It stores the image as `RGBA8_SRGB`, so the
GPU decodes it to linear on sample, which is what you want for a colour.

Hot reload comes for free: the watcher already rebuilds every asset when a `.png` changes
(`app_hot_reload.odin`), so editing the sky in a paint program updates the engine.

**Check:** you need a test panorama. The script below makes `test_sky.png` with a blue zenith, a warm horizon,
a dark ground, a sun straight ahead (+Z) and a **red post at +X**. Seen from inside, +X must be to the right
of +Z (left-handed, Y-up, +Z forward), so the post tells you if the sky ends up mirrored. Put the PNG in
`assets/skies/` and start the engine: the `Assets:` line in its stdout should show one more image than before.

<details><summary>Test panorama script (Python, standard library only)</summary>

```python
# python make_sky.py assets/skies/test_sky.png
# 512x256 equirectangular. Zenith blue -> warm horizon, dark ground below, a sun at u = 0.5 (+Z),
# 15 degrees up, and a red marker post at u = 0.75 (+X, the right of +Z) to check orientation.
import zlib, struct, math, sys
W, H = 512, 256
def lerp(a, b, t): return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))
rows = []
for y in range(H):
    elev = 90 - (y + 0.5) / H * 180   # degrees
    row = bytearray([0])
    for x in range(W):
        u = (x + 0.5) / W
        if elev >= 0:
            t = (elev / 90) ** 0.5
            c = lerp((250, 170, 110), (40, 70, 160), t)
            band = 0.5 + 0.5 * math.sin(u * 2 * math.pi * 6 + elev * 0.3)
            if 8 < elev < 35 and band > 0.8: c = lerp(c, (255, 235, 220), 0.5)
        else:
            c = lerp((70, 60, 55), (25, 25, 30), min(-elev / 30, 1))
        yaw = (u - 0.5) * 360
        if math.hypot(yaw, elev - 15) < 5: c = (255, 250, 220)
        if abs(u - 0.75) < 0.006 and -5 < elev < 40: c = (220, 30, 30)
        row += bytes(int(max(0, min(255, v))) for v in c) + b'\xff'
    rows.append(bytes(row))
def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0)) + \
      chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b'')
open(sys.argv[1], 'wb').write(png)
```

</details>

<details><summary>Reference code</summary>

In `asset_system_load`, the loop over `asset_files`:

```odin
    // Every PNG loads, keyed by its project path, whether or not a glTF uses it (a sky, say). First, so a glTF
    // that references one finds it by key (asset_system_import_gltf_models) instead of decoding it again.
    for fi in asset_files {
        if strings.to_lower(filepath.ext(fi.fullpath), context.temp_allocator) == ".png" {
            asset_system_import_png_image(fi.fullpath)
        }
    }
    // Then the kits, with their embedded images (.glb, data URIs) and any external one outside the scan.
    for fi in asset_files {
        ext := strings.to_lower(filepath.ext(fi.fullpath), context.temp_allocator)
        switch ext {
            case ".gltf", ".glb": asset_system_import_gltf_models(fi.fullpath)
        }
    }
```

</details>

---

## Step 2: The world setting

**You'll learn:** nested settings structs, `widget:texture`, and interning a key that came from text.

**Files:** `world.odin`, `loc.odin`, `world_scene.odin`, `app_remote.odin`.

**The idea:** a `Sky_Settings` struct nested in `World_Settings`, like `Fog_Settings`. Reflection gives you the
World Settings inspector section and the `sky.texture = …` lines in the `.level` file for free.

- `texture: string` tagged `widget:texture`: the inspector shows a dropdown of every loaded image key. Empty
  means no sky, so the background colour shows as before.
- `intensity: f32`: × the texture's linear colour. The texture tops out at 1, and this sets the sky's
  brightness against your lights. Default 1.
- `rotation: f32`, in degrees about +Y: turns the panorama to line up its painted sun with your directional
  light.

**The catch: interning.** CLAUDE.md: "anything that keeps a key interns it". Text decoding
(`deserialize_value`) clones strings into **temp** memory, which is gone next frame. The inspector's picker
already interns what you pick, but two other paths decode text into the settings: loading the scene
(`scene_load_world_settings`) and `blimpctl settings`. Give the asset system one proc,
`asset_intern_keys(v)`, that walks a struct by reflection and interns every string tagged with an asset picker's
widget (`widget:model`, `widget:texture`, `widget:sound`), and call it at both places. A key field added later
then needs only its tag. If you skip this, the key looks fine for one frame and then reads garbage.

**Check:** build, then `blimpctl settings 0` lists `sky.texture`, `sky.intensity`, `sky.rotation`.
`blimpctl settings 0 sky.texture assets/skies/test_sky.png` sets it, and World Settings shows it in the dropdown.

<details><summary>Reference code</summary>

`world.odin`, in `World_Settings` after `fog`:

```odin
    sky:        Sky_Settings `loc:World_Sky`,   // a panorama behind everything, in place of the background colour
```

The struct (next to `Fog_Settings`):

```odin
// The sky (claude/rendering.md → Sky): an equirectangular panorama (2:1, from assets/skies/) drawn behind the
// scene in place of the background colour. Its texels are sRGB, decoded to linear and × `intensity`: scene light
// like everything else, so exposure, fog and the tonemap apply. No texture: the background colour.
Sky_Settings :: struct {
    texture:   string `loc:World_Sky_Texture, widget:texture`,
    intensity: f32    `loc:World_Sky_Intensity`,   // × the texture's linear colour
    rotation:  f32    `loc:World_Sky_Rotation`,    // degrees about +Y
}
```

`asset_system.odin`, next to `asset_intern` (add `import "core:reflect"`; `type_is_struct` is in
`serialize.odin`):

```odin
// Interns (asset_intern) every asset key in `v`, a struct, nested structs included: its string fields tagged
// `widget:model`, `widget:texture` or `widget:sound`, the asset pickers' tags. For a struct decoded from text
// (deserialize_value leaves strings in temp memory, gone next frame) that keeps its keys, like World_Settings: a
// new key field needs only its tag. Pass the variable itself: `v` aliases it, as with struct_field_by_path.
asset_intern_keys :: proc(v: any) {
    for i in 0 ..< reflect.struct_field_count(v.id) {
        sf    := reflect.struct_field_at(v.id, i)
        field := reflect.struct_field_value(v, sf)
        if type_is_struct(sf.type.id) {
            asset_intern_keys(field)
        } else if key, is_string := field.(string); is_string && asset_key_field(sf.tag) {
            (^string)(field.data)^ = asset_intern(key)
        }
    }
}

@(private="file")
asset_key_field :: proc(tag: reflect.Struct_Tag) -> bool {
    for t in strings.split(string(tag), ",", context.temp_allocator) {
        switch strings.trim_space(t) {
        case "widget:model", "widget:texture", "widget:sound": return true
        }
    }
    return false
}
```

In `WORLD_SETTINGS_DEFAULT`:

```odin
    sky          = {intensity = 1},
```

`loc.odin`: add `World_Sky`, `World_Sky_Texture`, `World_Sky_Rotation` to the enum (after `World_Fog_Glow`), and
the rows. `World_Sky_Intensity` already exists (the Bake window uses it), so reuse it.

```odin
    .World_Sky          = { .EN = "Sky",            .ZH = "天空" },
    .World_Sky_Texture  = { .EN = "Panorama",       .ZH = "全景图" },
    .World_Sky_Rotation = { .EN = "Rotation (deg)", .ZH = "旋转（度）" },
```

`world_scene.odin`:

```odin
scene_load_world_settings :: proc(world: ^World, text: string) {
    ini_read_section(text, "world", world.settings)
    asset_intern_keys(world.settings)   // its keys (sky.texture) outlive the text
}
```

`app_remote.odin`, the `settings` command:

```odin
            deserialize_value(v, strings.join(args[2:], " ", context.temp_allocator))
            asset_intern_keys(w.settings)
            undo_push_settings_edited(w, before)
```

</details>

---

## Step 3: Frame constants

**You'll learn:** growing the constant buffer without breaking its layout.

**Files:** `render_dx.odin`, `common.slang`, `render_view.odin`.

**The idea:** the shader needs three values: the texture's bindless slot, the intensity and the rotation. They're
scalars, so they can't straddle a 16-byte row. Put them after `fog_glow`. Step 4 also needs the **scene target's
size** in pixels: add `scene_size: vec2` after `bone_buffer_slot`. At offset 468 it sits 4 bytes into its row and
ends at byte 12, so it doesn't straddle. `_padding` shrinks from 456 to 476. **Add the same fields at the same
places in `FrameConstants` in `common.slang`.**

Turning the key into a slot: `asset_system.image_ids[key]` gives the image index, and
`asset_buffers.texture_buffers[index].resource_view.heap_slot` gives its bindless slot, the same lookup the
materials use (`render_buffers.odin`). Write one small proc that answers "does this world have a sky to draw,
and which image?" Step 5 uses it again to decide whether to draw the pass at all.

Send the rotation in **turns** (degrees / 360). The shader works in texture coordinates, where one turn is 1.

**Check:** the build passes the `#assert`s. Nothing visible yet.

<details><summary>Reference code</summary>

`render_dx.odin`, in `Frame_Constants`:

```odin
    fog_glow:           f32,   // halos: per metre of haze, plus the height fog's density

    // The sky (World_Settings.sky, sky.slang), set only when the view draws one (render_view_sky).
    sky_texture_slot: u32,
    sky_intensity:    f32,
    sky_rotation:     f32,   // turns about +Y

    skin_buffer_slot: u32,   // Skin_Vertex per skinned vertex (asset)
    bone_buffer_slot: u32,   // the world's skin matrices this frame (World_Render.bones)
    scene_size:       vec2,  // the scene target in pixels: scene pixel → NDC without reading a texture (view.slang)

    _padding: [512 - 476]byte,   // CBVs come in 256-byte steps
}
#assert(offset_of(Frame_Constants, signal_texture_slot) == 312)
#assert(offset_of(Frame_Constants, _padding) == 476)
#assert(offset_of(Frame_Constants, scene_size) % 16 + size_of(vec2)  <= 16)
```

`common.slang`, the same places:

```slang
    public float    fogGlow;          // halos: per metre of haze, plus the height fog's density
    public uint     skyTextureSlot;   // the sky panorama (sky.slang); set only when the view draws a sky
    public float    skyIntensity;
    public float    skyRotation;      // turns about +Y
    public uint     skinBufferSlot;   // SkinVertex per skinned vertex (Mesh.skinOffset)
    public uint     boneBufferSlot;   // the world's skin matrices this frame (MeshInstance.boneOffset)
    public float2   sceneSize;        // the scene target in pixels (view.slang: scene_ndc)
```

`render_view.odin`, in the `Frame_Constants{…}` literal after `scene_cover`:

```odin
        scene_size             = {f32(view.target.scene_width), f32(view.target.scene_height)},
```

and after `render_view_fog(...)` in `render_view_update_constants`:

```odin
    render_view_sky(&frame_constants, world.settings.sky)
```

and the two procs:

```odin
// The sky's image: its texture setting, when that names a loaded image. A key nothing loaded under (a missing
// file) draws the background colour instead.
render_sky_image :: proc(sky: Sky_Settings) -> (image: u32, ok: bool) {
    if sky.texture == "" do return
    return asset_system.image_ids[sky.texture]
}

// World_Settings.sky → the frame constants, when there's a sky to draw.
render_view_sky :: proc(fc: ^Frame_Constants, sky: Sky_Settings) {
    image, ok := render_sky_image(sky)
    if !ok do return
    fc.sky_texture_slot = asset_buffers.texture_buffers[image].resource_view.heap_slot
    fc.sky_intensity    = max(sky.intensity, 0)
    fc.sky_rotation     = sky.rotation / 360
}
```

(`or_return` doesn't work in `render_view_sky`: it needs the proc to have a return value.)

</details>

---

## Step 4: The sky shader

**You'll learn:** going from a pixel to a world direction, and from a direction to equirectangular UVs.

**Files:** `sky.slang` (new), `view.slang`.

**The idea, in three parts:**

1. **Pixel → NDC.** `scene_ndc(px)` in `view.slang`, the same as the post pass uses. In a fragment shader
   `SV_Position.xy` is the pixel's centre, so `uint2(input.position.xy)` is its index. One catch it handles: in
   a retro view the scene target is a bit larger than what the display shows, and the scene VS squeezes the
   image into its top-left part (`scene_cover_clip`), so the squeeze has to be undone to get the projection's
   NDC. It used to get the target's size from the depth texture (`GetDimensions`), which the scene pass can't
   read: the depth texture is the bound depth target there. Read `gFrame.sceneSize` instead (step 3).
2. **NDC → world direction.** Factor it out of `view_ray` as `view_ray_dir(ndc)`: two points on the pixel's ray
   in view space (`view_pos` at depth 1, the near plane, and 0.5), their difference rotated into world space by
   `world_dir`. The fog and the sky then find a pixel's direction the same way. Perspective and ortho cameras
   both work, but an ortho camera sees one sky colour, since all its rays are parallel.
3. **Direction → UV.**
   - `u = atan2(d.x, d.z) / 2π + 0.5 − rotation`: the angle around +Y. +Z lands at `u = 0.5`, the middle of the
     image, and u grows toward +X, to the right.
   - `v = acos(d.y) / π`: 0 straight up, 1 straight down.

**Sample with `SampleLevel(…, 0)`, not `Sample`.** Behind the camera, u jumps from 1 back to 0 between two
neighbouring pixels. `Sample` works out the mip level from how fast the UV changes between pixels, sees a jump
of a whole texture, and picks the smallest mip: you get a one-pixel seam line. The sky is never minified
enough to need mips anyway.

Use the frame's sampler (`gFrame.samplerSlot`): point in retro views, linear in clean ones, the same as the
scene's textures. Its WRAP addressing handles u past 1 after rotation. Output the colour × `skyIntensity`
with alpha 1, like an opaque surface.

**A Slang/DXC gotcha**, if you ever pass something else from the vertex shader: every vertex output needs a
semantic. `float2 ndc;` alone fails with "Semantic must be defined for all outputs"; write `float2 ndc : NDC;`.

**Check:** nothing draws it yet. The shader compiles when step 5 creates the pipeline; an error panics at start
with the Slang message in stdout.

<details><summary>Reference code</summary>

`view.slang`, `scene_ndc` without the texture, and the direction shared with `view_ray`:

```slang
// Scene pixel px's centre as the projection's NDC: scene_cover_clip undone. Reads no texture, so any pass at the
// scene size can use it, the scene pass too (the sky), where the depth texture is the bound depth target.
public float2 scene_ndc(uint2 px) {
    float2 uv  = (float2(px) + 0.5) / gFrame.sceneSize;
    float2 ndc = float2(uv.x * 2 - 1, 1 - uv.y * 2);
    float2 cover = gFrame.sceneCover;
    return float2((ndc.x - (cover.x - 1)) / cover.x, (ndc.y - (1 - cover.y)) / cover.y);
}

// The world direction of the ray through ndc (scene_ndc): two points on it in view space, the near plane and
// depth 0.5, rotated into world space. Perspective and ortho alike (ortho: the same for every pixel).
public float3 view_ray_dir(float2 ndc) {
    return normalize(world_dir(view_pos(ndc, 0.5) - view_pos(ndc, 1)));
}
```

and in `view_ray`, `r.dir = view_ray_dir(ndc);`.

`assets_engine/shaders/sky.slang`:

```slang
module sky;

import "utils";
import "common";
import "view";

// PI: `public static const float PI = 3.14159265;` at the top of utils.slang, shared.

// The sky (World_Settings.sky, claude/rendering.md → Sky): one fullscreen triangle into the scene target, before
// the opaques, writing the panorama's linear light. No depth test or write: the depth stays the clear's 0, so the
// post pass fogs it as a ray that hit nothing.

struct VSOut {
    float4 position : SV_Position;
}

[shader("vertex")]
VSOut vert_main(uint vertexID : SV_VertexID) {
    VSOut o;
    o.position = fullscreen_triangle(vertexID);
    return o;
}

// The world direction through this pixel → the panorama: u is the angle around +Y (0.5 = +Z, increasing toward
// +X, then turned by skyRotation), v the angle down from straight up (0 = up, 1 = down). Equirectangular 2:1.
// SampleLevel, not Sample: u jumps from 1 to 0 behind the camera, and with derivatives that seam would pick the
// smallest mip and draw a line.
[shader("fragment")]
float4 frag_main(VSOut input) : SV_Target {
    float3 dir = view_ray_dir(scene_ndc(uint2(input.position.xy)));
    float2 uv = float2(atan2(dir.x, dir.z) / (2 * PI) + 0.5 - gFrame.skyRotation, acos(clamp(dir.y, -1, 1)) / PI);
    float3 c = getTexture2dRGBA(gFrame.skyTextureSlot).SampleLevel(getSampler(gFrame.samplerSlot), uv, 0).rgb;
    return float4(c * gFrame.skyIntensity, 1);
}
```

</details>

---

## Step 5: The pipeline, and drawing it

**You'll learn:** adding a pipeline the shader hot reload knows about, and inserting a draw into the scene pass.

**Files:** `render_dx.odin`, `render_view.odin`.

**The idea:** a `Shader_Pipeline` like the scene's, with:

- `rtv_format = VIEW_HDR_FORMAT`: it draws into the scene target.
- `depth_test = false`, `depth_write = false`, `cull_mode = .NONE`.
- The **default DSV format**, not `.UNKNOWN`. The scene pass has the depth buffer bound, and a PSO's DSV format
  must match what's bound even with depth off. The post passes use `.UNKNOWN` because they bind no depth.

Create it in `renderer_dx_init` next to the scene pipelines, destroy it in shutdown, and add it to
`renderer_dx_pipelines` so shader hot reload rebuilds it when you edit `sky.slang`.

In `render_view_draw`, the root signature, the frame constants and the triangle-list topology are all bound by
the time the blend loop starts. Before the loop, if the world has a sky, set the sky PSO and draw 3 vertices.
That's the whole draw.

The clear stays: with no sky texture, the clear colour is still the background, so worlds without a sky look
the same as before.

**Check:**

```
blimpctl settings 0 sky.texture assets/skies/test_sky.png
blimpctl camera 1 0 2 0 45 5 25          # level, looking between +Z and +X
blimpctl screenshot 1 sky.png
```

You should see the horizon level with the scene's horizon, the sun on the left (+Z), and the **red post on the
right** (+X). If the post is on the left, the sky is mirrored: check the sign of `d.x` in the `atan2`. Then try
fog: with `fog.distance_fog true` and `fog.max_opacity 0.6`, the sky stays 40% visible through the fog.

<details><summary>Reference code</summary>

`render_dx.odin`, in `Renderer_DX`:

```odin
    scene: [EntityBlend]Shader_Pipeline,   // scene.slang's vert_main with each blend's fragment entry point
    sky:   Shader_Pipeline,                // sky.slang: the panorama, drawn before the opaques
```

In `renderer_dx_init`, after the scene pipeline loop:

```odin
    // The sky: a fullscreen triangle under everything, so it neither tests nor writes depth (the clear's 0
    // stays, and the post pass's fog sees a ray that hit nothing).
    {
        opts := dx.PIPELINE_OPTIONS_DEFAULT
        opts.rtv_format  = VIEW_HDR_FORMAT
        opts.cull_mode   = .NONE
        opts.depth_test  = false
        opts.depth_write = false
        renderer_dx.sky = shader_pipeline_create("sky", "vert_main", "frag_main", opts)
    }
    render_post_init()   // post chain: HDR scene target → display target (render_post.odin)
```

In shutdown:

```odin
    for p in renderer_dx.scene do shader_pipeline_destroy(p)
    shader_pipeline_destroy(renderer_dx.sky)
```

In `renderer_dx_pipelines`:

```odin
    for &p in renderer_dx.scene do append(&list, &p)
    append(&list, &renderer_dx.sky)
```

`render_view.odin`, in `render_view_draw`, just before the blend loop:

```odin
    // The sky first, over the clear: everything else draws over it.
    if _, ok := render_sky_image(world.settings.sky); ok {
        cmd.handle->SetPipelineState(renderer_dx.sky.pso.handle)
        cmd.handle->DrawInstanced(3, 1, 0, 0)
    }
    // One range per blend, in EntityBlend order: everything opaque is in the depth buffer before anything blends.
```

</details>

---

## Step 6 (optional): The sky lights the probes

**You'll learn:** how the baker sees the sky, and filtering a texture down to what a bake can use.

**Files:** `editor_bake.odin`.

**The idea:** a bake ray that hits nothing returns `b.sky`, one flat colour (`bake.sky_color ×
bake.sky_intensity`, in `bake_radiance`). With a sky texture, it should return the sky's colour **in the
ray's direction** instead: blue light from above, warm light from the horizon. The bake's Sky Intensity still
multiplies it (default 1), and Include Sky still turns it off.

**One sky for both.** With a texture, the bake's own Sky Colour no longer means anything, and without one the
views show the background colour. So drop `bake.sky_color` altogether (the field, its picker in the Bake window,
its loc row, the line in `castle.level`) and make a miss with no texture the **background** × Sky Intensity.
The probes are then always lit by the sky the views draw.

Two things to get right:

- **Filter it first.** Probes store low-frequency light (SH), and each probe casts a few hundred rays. Sampling a
  detailed texture with that few rays just adds noise. At bake start, box-filter the image into a small table
  (32 × 16 cells) of linear radiance, and look each miss up in that.
- **Decode in linear.** The image's pixels stay in RAM (`asset_system.images[i].pixels`, RGBA8). An sRGB byte →
  `srgb_to_linear`. A 256-entry lookup table avoids millions of `pow` calls on a big sky, the same trick as
  `asset_build_albedos`.

Map directions exactly as `sky.slang` does, so the bake and the views agree. The editor layer may call
`render_sky_image`, since it sits above the renderer.

**Check:** bake, then read a probe in open air facing up and facing sideways:

```
blimpctl bake 0
blimpctl probe 0 0 8 0
```

With the test sky, +Y should go blue and the sides warm. In the copy this was built in, +Y went from
`0.28 0.36 0.60` (flat sky colour) to `0.16 0.13 0.24`, and ±X/±Z to about `0.19 0.12 0.13`.

<details><summary>Reference code</summary>

In `Bake`, after `sky`:

```odin
    sky:    vec3,                 // linear radiance of a miss (layer 0)
    sky_table: []vec3,            // or, with a sky texture, the miss radiance by direction (bake_sky_table); nil = sky
    sky_turn:  f32,               // the sky's rotation, turns
```

In `bake_probes`, replacing the `if set.sky do b.sky = …` line:

```odin
    if set.sky {
        // The sky the views show lights the probes: the sky texture, or else the background colour.
        b.sky = w.settings.background * set.sky_intensity
        if image, found := render_sky_image(w.settings.sky); found {
            sky := w.settings.sky
            b.sky_table = bake_sky_table(asset_system.images[image], max(sky.intensity, 0) * set.sky_intensity)
            b.sky_turn  = sky.rotation / 360
        }
    }
```

(`found`, not `ok`: `bake_probes` already has an `ok` result, and `-vet` rejects the shadowing.)

In `bake_radiance`, the miss:

```odin
    if !ok {
        t^ = max(f32)
        L[0] = bake_sky(b, r.dir)
        return
    }
```

The table and the lookup:

```odin
// The sky texture for the bake: box-filtered down to SKY_TABLE_W × SKY_TABLE_H cells of linear radiance. The
// probes hold only low-frequency light, and a few hundred rays per probe sampling the full texture would only add
// noise.
SKY_TABLE_W :: 32
SKY_TABLE_H :: 16

@(private="file")
bake_sky_table :: proc(img: Image, scale: f32) -> []vec3 {
    lut: [256]f32   // byte → linear
    for i in 0..<256 do lut[i] = img.format == .RGBA8_SRGB ? srgb_to_linear(f32(i) / 255) : f32(i) / 255
    table := make([]vec3, SKY_TABLE_W * SKY_TABLE_H, context.temp_allocator)
    count := make([]f32, len(table), context.temp_allocator)
    w, h := int(img.width), int(img.height)
    for y in 0..<h do for x in 0..<w {
        px := img.pixels[4 * (y * w + x):][:3]
        cell := (y * SKY_TABLE_H / h) * SKY_TABLE_W + x * SKY_TABLE_W / w
        table[cell] += {lut[px[0]], lut[px[1]], lut[px[2]]}
        count[cell] += 1
    }
    for &c, i in table do c *= scale / max(count[i], 1)
    return table
}

// A miss's radiance along unit direction d: the sky table's cell, mapped like sky.slang, or the sky colour.
@(private="file")
bake_sky :: proc(b: ^Bake, d: vec3) -> vec3 {
    if b.sky_table == nil do return b.sky
    u := math.atan2(d.x, d.z) / (2 * math.PI) + 0.5 - b.sky_turn
    v := math.acos(clamp(d.y, -1, 1)) / math.PI
    x := clamp(int((u - math.floor(u)) * SKY_TABLE_W), 0, SKY_TABLE_W - 1)
    y := clamp(int(v * SKY_TABLE_H), 0, SKY_TABLE_H - 1)
    return b.sky_table[y * SKY_TABLE_W + x]
}
```

In `ui_bake.odin`, remove the Sky Colour picker and `.World_Sky_Color` from the `labels` list that sizes the
label column (keep the list and `ui_label_column`: only that one entry goes).

</details>

---

## Step 7: Update the design doc

`claude/rendering.md`, "Shading is linear", says "A future sky is a fullscreen pass…". Make it present tense,
and add a short **Sky** section near Fog: the equirectangular PNGs from `assets/skies/`, the pass before the
opaques with no depth, why not HDR, `SampleLevel` for the seam, how the fog sees it (depth 0) and how the baker
does (the 32 × 16 table, if you did step 6).

---

## Notes and next ideas

- **Texture size.** A retro view is 384 pixels across for roughly 90° of view, so about 1536 pixels around the
  full circle gives one texel per pixel. 1024 × 512 to 2048 × 1024 suits the look; bigger is wasted.
- **Painting one.** Any paint program: the top row is straight up, the bottom row straight down, the middle row
  the horizon, and the centre column is +Z. Keep the left and right edges matching, since they meet behind you.
- **Fog colour vs sky.** Distance fog at a max opacity below 1 mixes its colour over the sky. A fog colour picked
  from the sky's horizon makes far geometry melt into the sky.
- **Moving clouds:** add a time-driven offset to `u` for a slow pan; that's one more constant.
