module shading;

// How surfaces take light: everything that lights a point (light_surface), and the shading models that use it,
// one function each. scene.slang only gathers the inputs and calls vertex_lighting (VS) and shade (PS).
//
// A new shading model: a member of ShadingModel and EntityShading (entity_schema.ini) and its case in
// entity_shading (render_buffers.odin); a SHADING_* constant here, at its member index; a shade_* function and
// its case in shade(). Per-vertex work goes in vertex_lighting.

import "utils";
import "common";
import "view";

// ShadingModel (entity_schema.ini), what an entity's shading resolves to (entity_shading in render_buffers.odin).
// Cheapest first.
public static const uint SHADING_UNLIT   = 0;
public static const uint SHADING_GOURAUD = 1;
public static const uint SHADING_LAMBERT = 2;
public static const uint SHADING_FLAT    = 3;
public static const uint SHADING_PHONG   = 4;

static const float3 AMBIENT         = 0.08;   // indirect light in a world with no baked probes
static const float  PHONG_SHININESS = 32;     // Blinn-Phong exponent: higher = smaller, sharper highlight
static const float  SPEC_STRENGTH   = 0.25;   // highlight brightness, × the light

// A point / spot / cylinder light's distance falloff at squared distance d2 from its source, over its
// range [innerRadius, radius] (the entity's range.x, range.y). Reaches exactly zero at radius in every mode.
float light_falloff(Light light, float d2) {
    float d = sqrt(d2);
    float inner = light.innerRadius;
    float outer = light.radius;
    switch (light.falloff) {
    case FALLOFF_LINEAR:
        return 1 - saturate((d - inner) / max(outer - inner, 0.0001));
    case FALLOFF_SMOOTH:
        return 1 - smoothstep(inner, max(outer, inner + 0.0001), d);
    default: {
        // Inverse square, windowed to zero at the range (Karis 2013, as in Unreal and Unity URP). Intensity
        // is the light at 1 unit; held flat inside the inner radius (the source's size) so it can't blow up.
        float r = d2 / (outer * outer);
        float window = saturate(1 - r * r);
        return window * window / max(d2, max(inner * inner, 0.0001));
    }
    }
}

// One baked probe: L2 SH of irradiance / π, 9 RGB coefficients (Probe_SH in render_probes.odin). A float array,
// not float3[9], so the structured-buffer layout can't differ from the Odin side.
struct Probe {
    float c[27];
    float _pad;
}

float3 sh_eval(Probe p, float3 n) {
    float b[9] = {
        0.282095,
        0.488603 * n.y, 0.488603 * n.z, 0.488603 * n.x,
        1.092548 * n.x * n.y, 1.092548 * n.y * n.z, 0.315392 * (3 * n.z * n.z - 1), 1.092548 * n.x * n.z, 0.546274 * (n.x * n.x - n.y * n.y),
    };
    float3 e = 0;
    for (uint i = 0; i < 9; i++) e += b[i] * float3(p.c[3 * i], p.c[3 * i + 1], p.c[3 * i + 2]);
    return e;
}

// One probe's depth map (Probe_Depth in render_probes.odin): PROBE_DEPTH_RES² octahedral texels, each the mean
// and mean² distance to the geometry that way, x fastest. A float array, like Probe.
static const uint  PROBE_DEPTH_RES    = 8;
static const float PROBE_NORMAL_BIAS  = 0.2;    // spacings the lit point moves off its surface before the test
static const float PROBE_MIN_VARIANCE = 1e-3;   // × spacing²
struct ProbeDepth {
    float t[2 * PROBE_DEPTH_RES * PROBE_DEPTH_RES];
}

float2 probe_depth_texel(ProbeDepth pd, uint x, uint y) {
    uint i = 2 * (y * PROBE_DEPTH_RES + x);
    return float2(pd.t[i], pd.t[i + 1]);
}

// How much a probe at probePos should count toward lighting q (already biased off its surface) facing N:
// a smooth backface term, then Chebyshev against the probe's depth map. Same as probe_visibility in
// render_probes.odin.
float probe_visibility(ProbeDepth pd, float3 probePos, float3 q, float3 N) {
    float3 toProbe = probePos - q;
    float  d = length(toProbe);
    if (d < 1e-5) return 1;
    toProbe /= d;

    float wrap = (dot(toProbe, N) + 1) * 0.5;
    float w = wrap * wrap + 0.2;

    float2 uv = octahedral_encode(-toProbe);
    float2 f  = clamp((uv * 0.5 + 0.5) * PROBE_DEPTH_RES - 0.5, 0, PROBE_DEPTH_RES - 1);
    uint2  i0 = uint2(f);
    uint2  i1 = min(i0 + 1, PROBE_DEPTH_RES - 1);
    float2 a  = f - float2(i0);
    float2 m  = lerp(lerp(probe_depth_texel(pd, i0.x, i0.y), probe_depth_texel(pd, i1.x, i0.y), a.x),
                     lerp(probe_depth_texel(pd, i0.x, i1.y), probe_depth_texel(pd, i1.x, i1.y), a.x), a.y);

    if (d > m.x) {
        float spacing  = gFrame.probeSpacing;
        float variance = max(m.y - m.x * m.x, PROBE_MIN_VARIANCE * spacing * spacing);
        float cheb = variance / (variance + (d - m.x) * (d - m.x));
        w *= cheb * cheb * cheb;
    }
    return max(w, 1e-6);
}

// The SH's constant band: the probe's light averaged over every direction. Irradiance / π convolves only the
// higher bands, so this is also the average radiance arriving there. probe_light_mean in world_probes.odin.
float3 sh_mean(Probe p) {
    return 0.282095 * float3(p.c[0], p.c[1], p.c[2]);
}

// Baked indirect light (irradiance / π) reaching a surface at pos facing N: trilinear between the 8 probes
// around it, clamped to the grid outside it, each probe's layers times their light group's scale (layer k of
// the buffer starts k × the probe count in), each corner weighted by its visibility and the weights
// renormalized, so light doesn't leak through walls. Same as probe_grid_sample in render_probes.odin.
// N = 0 is a point in the air (fog): no normal bias, no backface term, and each probe's average light.
// `weight` is the corners' total weight before renormalizing: near zero where no probe sees the point.
float3 probe_grid(float3 pos, float3 N, out float weight) {
    StructuredBuffer<Probe> probes = DescriptorHandle<StructuredBuffer<Probe>>(gFrame.probeBufferSlot);
    StructuredBuffer<ProbeDepth> depth = DescriptorHandle<StructuredBuffer<ProbeDepth>>(gFrame.probeDepthSlot);
    uint3  dims = gFrame.probeDims;
    uint   count = dims.x * dims.y * dims.z;
    bool   air = all(N == 0);
    float3 q  = pos + N * (PROBE_NORMAL_BIAS * gFrame.probeSpacing);
    float3 u  = clamp((q - gFrame.probeOrigin) / gFrame.probeSpacing, 0, float3(dims - 1));
    uint3  i0 = min(uint3(u), dims - 1);
    uint3  i1 = min(i0 + 1, dims - 1);
    float3 f  = u - float3(i0);
    float3 e = 0;
    float  total = 0;
    for (uint c = 0; c < 8; c++) {
        uint3  i = uint3((c & 1) != 0 ? i1.x : i0.x, (c & 2) != 0 ? i1.y : i0.y, (c & 4) != 0 ? i1.z : i0.z);
        float3 t = float3((c & 1) != 0 ? f.x : 1 - f.x, (c & 2) != 0 ? f.y : 1 - f.y, (c & 4) != 0 ? f.z : 1 - f.z);
        float  w = t.x * t.y * t.z;
        if (w == 0) continue;
        uint index = i.x + dims.x * (i.y + dims.y * i.z);
        w *= probe_visibility(depth[index], gFrame.probeOrigin + gFrame.probeSpacing * float3(i), q, N);
        for (uint k = 0; k < gFrame.probeLayers; k++) {
            float scale = gFrame.probeLayerScale[k / 4][k % 4];
            if (scale == 0) continue;
            Probe p = probes[k * count + index];
            e += w * scale * (air ? sh_mean(p) : sh_eval(p, N));
        }
        total += w;
    }
    weight = total;
    return max(e / max(total, 1e-6), 0);
}

float3 probe_irradiance(float3 pos, float3 N) {
    float weight;
    return probe_grid(pos, N, weight);
}

// One shadow map slice's camera: Shadow_View in render_shadows.odin (256 bytes; the shadow pass reads the
// same entries as its constants).
struct ShadowView {
    float4x4 viewProj;
    uint4    slots;
    float4   _pad[11];
}

static const float SHADOW_NORMAL_OFFSET = 1.5;   // receivers move this many shadow texels along their normal: no acne

// 1 where `light` reaches pos (facing N), 0 where something in its shadow map is in the way. Hard: one
// point-sampled texel, no filtering (claude/rendering.md, Shadows). Unshadowed outside the light's map.
float shadow_visibility(Light light, float3 pos, float3 N) {
    if (light.shadowSlice == SHADOW_NONE) return 1;
    StructuredBuffer<ShadowView> views = DescriptorHandle<StructuredBuffer<ShadowView>>(gFrame.shadowViewBufferSlot);
    Texture2DArray<float> shadowMap = DescriptorHandle<Texture2DArray<float>>(gFrame.shadowMapSlot);

    // Texels of a perspective map (spot, point) grow with distance; orthographic ones (directional, cylinder) don't.
    bool perspective = light.type == LIGHT_SPOT || light.type == LIGHT_POINT;
    float texel = light.shadowTexel * (perspective ? length(pos - light.position) : 1);
    float3 p = pos + N * texel * SHADOW_NORMAL_OFFSET;

    uint slice = light.shadowSlice;
    if (light.type == LIGHT_POINT) {
        // The cube face the point falls in, by its major axis: +X −X +Y −Y +Z −Z (light_shadow_cameras).
        float3 v = p - light.position;
        float3 a = abs(v);
        if (a.x >= a.y && a.x >= a.z) slice += v.x >= 0 ? 0 : 1;
        else if (a.y >= a.z)          slice += v.y >= 0 ? 2 : 3;
        else                          slice += v.z >= 0 ? 4 : 5;
    }
    float4 clip = mul(float4(p, 1), views[slice].viewProj);
    if (clip.w <= 0) return 1;
    float3 ndc = clip.xyz / clip.w;
    float2 uv  = ndc.xy * float2(0.5, -0.5) + 0.5;
    if (any(uv < 0) || any(uv > 1) || ndc.z < 0 || ndc.z > 1) return 1;
    int2 t = min(int2(uv * SHADOW_MAP_SIZE), int(SHADOW_MAP_SIZE - 1));
    float nearest = shadowMap.Load(int4(t, slice, 0));
    return ndc.z >= nearest ? 1 : 0;   // reversed-Z: the caster nearest the light has the largest depth
}

// The light reaching a surface point: what the albedo is multiplied by (diffuse) and what's added on top
// (specular, already in light units: a white highlight whatever the albedo).
public struct Lighting {
    public float3 diffuse;
    public float3 specular;
}

// Whether the view shows direct light, and what it scales indirect light by (Lighting_View in
// render_view.odin). The view that lights a white surface is the pixel shader's.
public bool view_direct() {
    return gFrame.lightingView != LIGHTING_PROBES_ONLY && gFrame.lightingView != LIGHTING_INDIRECT_ONLY;
}
float indirect_scale() {
    return gFrame.lightingView == LIGHTING_DIRECT_ONLY ? 0 : gFrame.indirectScale;
}

// Baked indirect light reaching pos facing N (AMBIENT when not baked).
float3 indirect_light(float3 pos, float3 N) {
    float3 e = gFrame.probeDims.x > 0 ? probe_irradiance(pos, N) : AMBIENT;
    return e * indirect_scale();
}

// Baked light in the air at pos (the probes'), averaged over every direction: what lit fog follows. Only
// called with probes baked. `seen` is how well the probes see pos: 1 in open air, toward 0 inside walls,
// under the ground or out past the grid, where the light it gives means nothing.
public float3 air_light(float3 pos, out float seen) {
    float3 e = probe_grid(pos, 0, seen);
    seen = saturate(seen / 0.45);   // probe_visibility's backface term with no normal: an unoccluded point's weight
    return e;
}

// How much of `light` arrives at pos (distance falloff, cone and beam edges; not shadow), and the unit
// direction toward it in L.
public float light_reach(Light light, float3 pos, out float3 L) {
    if (light.type == LIGHT_DIRECTIONAL) {
        L = -light.direction;   // the light shines along its +Z
        return 1;
    }
    if (light.type == LIGHT_CYLINDER) {
        // A spot with a cylinder-shaped beam: parallel rays along its +Z from a disc at its position.
        // Falls off along the beam (distance from the disc, nothing behind it) and, like a spot's cone
        // edge, across it: full inside the inner radius, squared fade to zero at the outer.
        L = -light.direction;
        float3 rel   = pos - light.position;
        float  along = dot(rel, light.direction);
        float  across = length(rel - light.direction * along);
        float  t = saturate((light.beamRadius - across) / max(light.beamRadius - light.beamInner, 0.0001));
        return along > 0 ? light_falloff(light, along * along) * t * t : 0;
    }
    float3 toLight = light.position - pos;
    float d2 = max(dot(toLight, toLight), 1e-8);
    L = toLight * rsqrt(d2);
    float atten = light_falloff(light, d2);
    if (light.type == LIGHT_SPOT) {
        // Full inside the inner cone, squared fade to zero at the outer (Unreal's spot falloff).
        float t = saturate((dot(-L, light.direction) - light.cosOuter) / max(light.cosInner - light.cosOuter, 0.0001));
        atten *= t * t;
    }
    return atten;
}

// Everything that lights `pos` facing N, seen from direction V: baked indirect, then every light in the world
// with its shadow, or a headlight when there are none. Blinn-Phong highlights of `shininess`; 0 = none.
// `translucency` (the material's, 0 = opaque) is thin translucency: that share of the light on the back face
// comes through diffusely, so a lamp shade glows from the bulb inside it (claude/rendering.md).
// Everything here is linear: light colours are, and the result goes to a float target that the post pass
// encodes for display.
public Lighting light_surface(float3 pos, float3 N, float3 V, float shininess, float translucency) {
    StructuredBuffer<Light> lightBuffer = DescriptorHandle<StructuredBuffer<Light>>(gFrame.lightBufferSlot);
    Lighting result = { indirect_light(pos, N), 0 };
    bool direct = view_direct();
    uint lightCount = direct ? gFrame.lightCount : 0;

    for (uint i = 0; i < lightCount; i++) {
        Light light = lightBuffer[i];
        float3 L;
        float atten = light_reach(light, pos, L);
        if (atten <= 0) continue;
        float3 radiance = light.color * light.intensity * atten;
        float ndl = saturate(dot(N, L));
        if (ndl > 0) {
            float3 lit = radiance * shadow_visibility(light, pos, N);
            result.diffuse += ndl * lit;
            if (shininess > 0) {   // no highlight on the far side
                float3 H = normalize(L + V);
                result.specular += pow(saturate(dot(N, H)), shininess) * SPEC_STRENGTH * lit;
            }
        }
        // The back face's light, through the surface. Its shadow is looked up from the back side (-N): offset
        // the other way, the surface itself would be in front of the point and shadow it.
        float back = translucency * saturate(dot(-N, L));
        if (back > 0) result.diffuse += back * radiance * shadow_visibility(light, pos, -N);
    }
    // A world with no lights (a kit, a new level) gets a headlight: white, intensity 1, shining from the
    // view's eye, so whatever the view looks at is lit. Per view, unshadowed, never baked.
    if (direct && gFrame.lightCount == 0) {
        float ndv = saturate(dot(N, V));
        result.diffuse += ndv;
        if (shininess > 0 && ndv > 0) result.specular += pow(ndv, shininess) * SPEC_STRENGTH;   // L = V, so H = V
    }
    return result;
}

// The face's own normal at pos, from screen-space derivatives, turned toward the eye (back faces are culled,
// so the side we see is the front).
public float3 face_normal(float3 pos) {
    float3 n = normalize(cross(ddx(pos), ddy(pos)));
    return dot(n, view_dir(pos)) < 0 ? -n : n;
}

// ------------------------------------------------------------------------------------------------------
// The shading models, cheapest first (ShadingModel's order)

// The vertex shader's share, for the rasterizer to interpolate: Gouraud's light. Zero for per-pixel models.
// A shadow can't be interpolated (an edge between two vertices would vanish), so the first
// GOURAUD_SHADOW_LIGHTS shadowed lights come apart: each one's light per vertex in `shadowed`, its index in
// `shadowLight` (the same for every vertex), and the pixel shader shadows each. Any more shadow per vertex.
public static const uint GOURAUD_SHADOW_LIGHTS = 4;

public struct VertexLight {
    public float3 diffuse;                           // indirect, unshadowed lights, shadowed ones past the cap
    public float3 shadowed[GOURAUD_SHADOW_LIGHTS];   // each shadowed light, before its shadow
    public uint4  shadowLight;                       // their indices in the light buffer, SHADOW_NONE = unused
}

public VertexLight vertex_lighting(uint shading, float3 pos, float3 N, float translucency) {
    VertexLight v = {};
    v.shadowLight = SHADOW_NONE;
    if (shading != SHADING_GOURAUD) return v;

    StructuredBuffer<Light> lightBuffer = DescriptorHandle<StructuredBuffer<Light>>(gFrame.lightBufferSlot);
    v.diffuse = indirect_light(pos, N);
    bool direct = view_direct();
    uint lightCount = direct ? gFrame.lightCount : 0;
    uint shadowedCount = 0;
    for (uint i = 0; i < lightCount; i++) {
        Light light = lightBuffer[i];
        float3 L;
        float atten = light_reach(light, pos, L);
        float3 radiance = atten * light.color * light.intensity;
        float3 c = saturate(dot(N, L)) * radiance;
        // Back-face light through a translucent surface (light_surface), shadowed here per vertex from the back
        // side: the pixel shader's shadows are for the front.
        float back = translucency * saturate(dot(-N, L));
        if (back > 0 && atten > 0) v.diffuse += back * radiance * shadow_visibility(light, pos, -N);
        if (light.shadowSlice != SHADOW_NONE && shadowedCount < GOURAUD_SHADOW_LIGHTS) {
            v.shadowed[shadowedCount] = c;
            v.shadowLight[shadowedCount] = i;
            shadowedCount++;
        } else {
            if (any(c > 0)) c *= shadow_visibility(light, pos, N);   // 1 for an unshadowed light
            v.diffuse += c;
        }
    }
    if (direct && gFrame.lightCount == 0) v.diffuse += saturate(dot(N, view_dir(pos)));   // the headlight
    return v;
}

// No light: texture × material × vertex colour, as authored.
float3 shade_unlit(float3 albedo) {
    return albedo;
}

// Lit at the vertices, interpolated across the face; shadows per pixel (vertex_lighting). Diffuse only, as on
// the PS1: a highlight that falls between vertices would just vanish.
float3 shade_gouraud(float3 albedo, float3 pos, float3 N, VertexLight v) {
    StructuredBuffer<Light> lightBuffer = DescriptorHandle<StructuredBuffer<Light>>(gFrame.lightBufferSlot);
    float3 light = v.diffuse;
    for (uint k = 0; k < GOURAUD_SHADOW_LIGHTS; k++) {
        if (v.shadowLight[k] == SHADOW_NONE) break;
        if (any(v.shadowed[k] > 0)) light += v.shadowed[k] * shadow_visibility(lightBuffer[v.shadowLight[k]], pos, N);
    }
    return albedo * light;
}

// Lit per pixel with the interpolated normal, diffuse only: smooth, no highlight.
float3 shade_lambert(float3 albedo, float3 pos, float3 N, float translucency) {
    return albedo * light_surface(pos, N, view_dir(pos), 0, translucency).diffuse;
}

// Lit per pixel with the face's normal (N, the caller's face_normal), ignoring the mesh's smooth ones:
// faceted. Diffuse only.
float3 shade_flat(float3 albedo, float3 pos, float3 N, float translucency) {
    return albedo * light_surface(pos, N, view_dir(pos), 0, translucency).diffuse;
}

// Lit per pixel, with a highlight.
float3 shade_phong(float3 albedo, float3 pos, float3 N, float translucency) {
    Lighting l = light_surface(pos, N, view_dir(pos), PHONG_SHININESS, translucency);
    return albedo * l.diffuse + l.specular;
}

// The surface colour at pos, by shading model (SHADING_*). N is the interpolated normal, or for Flat the
// face's (face_normal, taken by the caller before any texel snap moves pos); v what vertex_lighting gave for
// this model; `translucency` the material's (light_surface; Gouraud's is already in v). `shading` is per draw,
// so the branch is uniform.
public float3 shade(uint shading, float3 albedo, float3 pos, float3 N, VertexLight v, float translucency) {
    switch (shading) {
    case SHADING_UNLIT:   return shade_unlit(albedo);
    case SHADING_GOURAUD: return shade_gouraud(albedo, pos, N, v);
    case SHADING_FLAT:    return shade_flat(albedo, pos, N, translucency);
    case SHADING_PHONG:   return shade_phong(albedo, pos, N, translucency);
    default:              return shade_lambert(albedo, pos, N, translucency);
    }
}
