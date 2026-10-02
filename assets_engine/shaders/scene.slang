module scene;

import "utils";
import "common";

public struct MeshInstance {
    public uint transformIndex;
    public uint mesh;
    public uint material;
}

public struct Mesh {
    public uint indexOffset;
    public uint indexCount;
    public uint vertexOffset;
    public uint vertexCount;
    public uint material;   // asset default material; the shader reads material from the instance, not here
}

public struct Attributes {
    public float4 color;
    public float3 normal;
    public float2 uv0;
}

public struct Material {
    public float4 color;
    public uint colorTex;
}

public struct VSIn {
    uint instanceID    : SV_InstanceID;
    uint startInstance : SV_StartInstanceLocation;
    uint vertexID      : SV_VertexID;
}

public struct VSOut {
    public float4 position : SV_Position;
    public float4 color : COLOR;
    public float3 normal : NORMAL;
    public float2 uv0 : TEXCOORD0;
    // The same UVs interpolated linearly in screen space: the PS1's affine texture warp. Interpolation
    // is fixed per varying, so both ride along and the PS blends them by gFrame.affine (one PSO for both modes).
    public noperspective float2 uvAffine : TEXCOORD3;
    public float3 worldPos : TEXCOORD2;
    public nointerpolation uint material : TEXCOORD1;
}

[shader("vertex")]
public VSOut vert_main(VSIn input) {
    StructuredBuffer<MeshInstance> meshInstanceBuffer = DescriptorHandle<StructuredBuffer<MeshInstance>>(gFrame.meshInstanceBufferSlot);
    StructuredBuffer<Mesh>         meshBuffer         = DescriptorHandle<StructuredBuffer<Mesh>>(gFrame.meshBufferSlot);
    StructuredBuffer<float4x4>     transformBuffer    = DescriptorHandle<StructuredBuffer<float4x4>>(gFrame.transformBufferSlot);
    StructuredBuffer<float3>       positionBuffer     = DescriptorHandle<StructuredBuffer<float3>>(gFrame.positionBufferSlot);
    StructuredBuffer<Attributes>   attributeBuffer    = DescriptorHandle<StructuredBuffer<Attributes>>(gFrame.attributeBufferSlot);

    MeshInstance meshInstance = meshInstanceBuffer[input.startInstance + input.instanceID];
    Mesh         mesh         = meshBuffer[meshInstance.mesh];

    uint transformIndex = meshInstance.transformIndex;
    float4x4 transform = transformBuffer[transformIndex];

    uint vertexIndex = mesh.vertexOffset + input.vertexID;

    float4 worldPos = mul(float4(positionBuffer[vertexIndex], 1.0), transform);

    // Cofactor of the upper 3x3 = inverse-transpose up to scale: correct under non-uniform scale.
    // Rows are the basis vectors (row-vector convention, as in mul(p, transform) above).
    float3 r0 = transform[0].xyz;
    float3 r1 = transform[1].xyz;
    float3 r2 = transform[2].xyz;
    float3x3 cofactor = float3x3(cross(r1, r2), cross(r2, r0), cross(r0, r1));
    float flip = sign(dot(r0, cross(r1, r2)));   // mirrored scale (negative det) would invert the normal

    VSOut output;
    float4 clip = mul(mul(worldPos, gFrame.viewMat), gFrame.projMat);
    // The scene target is the display size / sceneScale rounded up, so the display covers only its top-left
    // sceneCover part. Squeeze NDC into that part (left and top edges fixed): the image lines up with the
    // display pixel for pixel, and the projection stays the display's (picking, debug lines).
    float2 cover = gFrame.sceneCover;
    clip.x = clip.x * cover.x + (cover.x - 1) * clip.w;
    clip.y = clip.y * cover.y + (1 - cover.y) * clip.w;
    // PS1 vertex jitter: round the screen position to whole scene pixels, then multiply back by w so the
    // depth and perspective division are untouched. Skip vertices behind the eye (w <= 0), which the
    // divide would fling across the screen; the clipper handles them. Skinning, when it lands, goes before this.
    if (gFrame.vertexSnap.x > 0 && clip.w > 0) {
        clip.xy = round(clip.xy / clip.w * gFrame.vertexSnap) / gFrame.vertexSnap * clip.w;
    }
    output.position = clip;
    output.worldPos = worldPos.xyz;
    output.color = attributeBuffer[vertexIndex].color;
    output.normal = mul(attributeBuffer[vertexIndex].normal, cofactor) * flip;
    output.uv0 = attributeBuffer[vertexIndex].uv0;
    output.uvAffine = output.uv0;
    output.material = meshInstance.material;
    return output;
}

static const float3 AMBIENT       = 0.08;   // indirect light in a world with no baked probes
static const float  SHININESS     = 32;
static const float  SPEC_STRENGTH = 0.25;

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

// Baked indirect light (irradiance / π) reaching a surface at pos facing N: trilinear between the 8 probes
// around it, clamped to the grid outside it, each probe's layers times their light group's scale (layer k of
// the buffer starts k × the probe count in). Same as probe_grid_sample in render_probes.odin.
float3 probe_irradiance(float3 pos, float3 N) {
    StructuredBuffer<Probe> probes = DescriptorHandle<StructuredBuffer<Probe>>(gFrame.probeBufferSlot);
    uint3  dims = gFrame.probeDims;
    uint   count = dims.x * dims.y * dims.z;
    float3 u  = clamp((pos - gFrame.probeOrigin) / gFrame.probeSpacing, 0, float3(dims - 1));
    uint3  i0 = min(uint3(u), dims - 1);
    uint3  i1 = min(i0 + 1, dims - 1);
    float3 f  = u - float3(i0);
    float3 e = 0;
    for (uint c = 0; c < 8; c++) {
        uint3  i = uint3((c & 1) != 0 ? i1.x : i0.x, (c & 2) != 0 ? i1.y : i0.y, (c & 4) != 0 ? i1.z : i0.z);
        float3 w = float3((c & 1) != 0 ? f.x : 1 - f.x, (c & 2) != 0 ? f.y : 1 - f.y, (c & 4) != 0 ? f.z : 1 - f.z);
        uint index = i.x + dims.x * (i.y + dims.y * i.z);
        for (uint k = 0; k < gFrame.probeLayers; k++) {
            float scale = gFrame.probeLayerScale[k / 4][k % 4];
            if (scale != 0) e += w.x * w.y * w.z * scale * sh_eval(probes[k * count + index], N);
        }
    }
    return max(e, 0);
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
// point-sampled texel, no filtering (docs/rendering.md, Shadows). Unshadowed outside the light's map.
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

[shader("fragment")]
float4 frag_main(VSOut input) : SV_Target {
    StructuredBuffer<Material> materialBuffer = DescriptorHandle<StructuredBuffer<Material>>(gFrame.materialBufferSlot);
    StructuredBuffer<Light>    lightBuffer    = DescriptorHandle<StructuredBuffer<Light>>(gFrame.lightBufferSlot);
    Material material = materialBuffer[input.material];

    Texture2D<float4> tex = getTexture2dRGBA(material.colorTex);
    SamplerState samp = getSampler(gFrame.samplerSlot);
    float2 uv = lerp(input.uv0, input.uvAffine, gFrame.affine);
    float4 albedo = tex.Sample(samp, uv) * material.color * input.color;

    float3 N = normalize(input.normal);   // interpolation de-normalizes it
    float3 V = normalize(gFrame.cameraPos - input.worldPos);

    // Blinn-Phong, per pixel, every light in the world. Everything here is linear: colour textures are
    // sRGB views (decoded on sample), material and vertex colours are linear (glTF), and the output goes
    // to a float target that the post pass encodes for display.
    // Lighting debug views (Lighting_View in render_view.odin) drop terms or light a white surface.
    uint lightingView = gFrame.lightingView;
    if (lightingView == LIGHTING_PROBES_ONLY || lightingView == LIGHTING_LIGHTING_ONLY) albedo.rgb = 1;
    float3 indirect = AMBIENT;
    if (gFrame.probeDims.x > 0) indirect = probe_irradiance(input.worldPos, N);
    indirect *= lightingView == LIGHTING_DIRECT_ONLY ? 0 : gFrame.indirectScale;
    uint lightCount = (lightingView == LIGHTING_PROBES_ONLY || lightingView == LIGHTING_INDIRECT_ONLY) ? 0 : gFrame.lightCount;

    float3 lit = albedo.rgb * indirect;
    for (uint i = 0; i < lightCount; i++) {
        Light light = lightBuffer[i];
        float3 L;
        float atten = 1;
        if (light.type == LIGHT_DIRECTIONAL) {
            L = -light.direction;   // the light shines along its +Z
        } else if (light.type == LIGHT_CYLINDER) {
            // A spot with a cylinder-shaped beam: parallel rays along its +Z from a disc at its position.
            // Falls off along the beam (distance from the disc, nothing behind it) and, like a spot's cone
            // edge, across it: full inside the inner radius, squared fade to zero at the outer.
            L = -light.direction;
            float3 rel   = input.worldPos - light.position;
            float  along = dot(rel, light.direction);
            float  across = length(rel - light.direction * along);
            float  t = saturate((light.beamRadius - across) / max(light.beamRadius - light.beamInner, 0.0001));
            atten = along > 0 ? light_falloff(light, along * along) * t * t : 0;
        } else {
            float3 toLight = light.position - input.worldPos;
            float d2 = max(dot(toLight, toLight), 1e-8);
            L = toLight * rsqrt(d2);
            atten = light_falloff(light, d2);
            if (light.type == LIGHT_SPOT) {
                // Full inside the inner cone, squared fade to zero at the outer (Unreal's spot falloff).
                float t = saturate((dot(-L, light.direction) - light.cosOuter) / max(light.cosInner - light.cosOuter, 0.0001));
                atten *= t * t;
            }
        }
        float ndl  = saturate(dot(N, L));
        if (ndl > 0 && atten > 0) atten *= shadow_visibility(light, input.worldPos, N);
        float3 H   = normalize(L + V);
        float spec = ndl > 0 ? pow(saturate(dot(N, H)), SHININESS) * SPEC_STRENGTH : 0;   // no highlight on the far side
        lit += (albedo.rgb * ndl + spec) * light.color * light.intensity * atten;
    }
    return float4(lit, 1);   // alpha 1 = scene coverage: the post pass leaves alpha-0 (background) pixels alone
}