module scene;

import "utils";
import "common";
import "shading";
import "view";

public struct MeshInstance {
    public uint transformIndex;
    public uint mesh;
    public uint material;
    public uint shading;   // SHADING_* (shading.slang)
    public float4 tint;    // the entity's color × intensity (entity_tint), alpha 1: multiplies the albedo
    public uint boneOffset;   // its entity's skin matrices in the bone buffer; 0xFFFFFFFF = draw the mesh as stored (rest pose)
    public uint3 _pad;
}

public struct Mesh {
    public uint indexOffset;
    public uint indexCount;
    public uint vertexOffset;
    public uint vertexCount;
    public uint material;   // asset default material; the shader reads material from the instance, not here
    public uint skinOffset;   // into the skin buffer, parallel to the vertices; 0xFFFFFFFF = static
    public uint2 _pad;
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
    public nointerpolation uint shading : TEXCOORD4;
    // vertex_lighting's VertexLight (Gouraud), field by field; zero for models lit per pixel.
    public float3 vertexDiffuse : TEXCOORD5;
    public float3 vertexShadowed0 : TEXCOORD6;
    public float3 vertexShadowed1 : TEXCOORD7;
    public float3 vertexShadowed2 : TEXCOORD8;
    public float3 vertexShadowed3 : TEXCOORD9;
    public nointerpolation uint4 vertexShadowLight : TEXCOORD10;
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

    // Skinning: model space, before the entity transform (and so before the PS1 snap below). Uniform per draw.
    float3 localPos    = positionBuffer[vertexIndex];
    float3 localNormal = attributeBuffer[vertexIndex].normal;
    if (mesh.skinOffset != 0xFFFFFFFF && meshInstance.boneOffset != 0xFFFFFFFF) {
        float4x4 skin = skinMatrix(gFrame.skinBufferSlot, gFrame.boneBufferSlot, mesh.skinOffset + input.vertexID, meshInstance.boneOffset);
        localPos    = mul(float4(localPos, 1.0), skin).xyz;
        localNormal = mul(float4(localNormal, 0.0), skin).xyz;
    }

    float4 worldPos = mul(float4(localPos, 1.0), transform);

    // Cofactor of the upper 3x3 = inverse-transpose up to scale: correct under non-uniform scale.
    // Rows are the basis vectors (row-vector convention, as in mul(p, transform) above).
    float3 r0 = transform[0].xyz;
    float3 r1 = transform[1].xyz;
    float3 r2 = transform[2].xyz;
    float3x3 cofactor = float3x3(cross(r1, r2), cross(r2, r0), cross(r0, r1));
    float flip = sign(dot(r0, cross(r1, r2)));   // mirrored scale (negative det) would invert the normal

    VSOut output;
    float4 clip = mul(mul(worldPos, gFrame.viewMat), gFrame.projMat);
    clip = scene_cover_clip(clip);   // into the part of the scene target the display covers
    // PS1 vertex jitter: round the screen position to whole scene pixels, then multiply back by w so the
    // depth and perspective division are untouched. Skip vertices behind the eye (w <= 0), which the
    // divide would fling across the screen; the clipper handles them.
    if (gFrame.vertexSnap.x > 0 && clip.w > 0) {
        clip.xy = round(clip.xy / clip.w * gFrame.vertexSnap) / gFrame.vertexSnap * clip.w;
    }
    output.position = clip;
    output.worldPos = worldPos.xyz;
    output.color = attributeBuffer[vertexIndex].color * meshInstance.tint;   // constant per draw, so per vertex is per pixel
    output.normal = mul(localNormal, cofactor) * flip;
    output.uv0 = attributeBuffer[vertexIndex].uv0;
    output.uvAffine = output.uv0;
    output.material = meshInstance.material;
    output.shading = meshInstance.shading;
    VertexLight vertexLight = vertex_lighting(meshInstance.shading, output.worldPos, normalize(output.normal));
    static_assert(GOURAUD_SHADOW_LIGHTS == 4, "VSOut carries four vertexShadowed");
    output.vertexDiffuse = vertexLight.diffuse;
    output.vertexShadowed0 = vertexLight.shadowed[0];
    output.vertexShadowed1 = vertexLight.shadowed[1];
    output.vertexShadowed2 = vertexLight.shadowed[2];
    output.vertexShadowed3 = vertexLight.shadowed[3];
    output.vertexShadowLight = vertexLight.shadowLight;
    return output;
}

static const float CUTOUT_ALPHA = 0.5;   // a Cutout surface's pixels below this alpha are cut

// The colour of one pixel of a surface: its albedo, lit by its shading model (shading.slang). `cutout` and
// `blended` are the entity's blend (EntityBlend), fixed per entry point below.
// Texel-snapped lighting (Retro_Settings.texel_lighting): moves the point that's lit, and its normal, to the
// centre of the colour-texture texel `uv` falls in, so light changes in steps aligned to the texture. Exact
// inside a triangle: position, normal and UV all vary linearly across it, so the screen-space derivatives
// turn a step in UV into a step in position. A texel cut by an edge is lit on each side from the plane of
// that side's triangle. The texel is the one at the mip the sampler picks, so far surfaces snap coarser
// instead of shimmering. Snap with perspective-correct UVs (uv0): position only follows those.
// A texel wider than TEXEL_SNAP_MAX_PIXELS on screen isn't a texel the eye reads as one but a palette swatch
// (a kit whose faces each sit in one colour of an atlas) or squashed UVs: no snap, since the step there is
// near-zero over near-zero and would light each quad from somewhere arbitrary.
static const float TEXEL_SNAP_MAX_PIXELS = 32;

void texel_snap(Texture2D<float4> tex, SamplerState samp, float2 uv, inout float3 pos, inout float3 N) {
    // Every derivative first, while the whole quad is still here.
    float2 uvX = ddx(uv), uvY = ddy(uv);
    float3 posX = ddx(pos), posY = ddy(pos);
    float3 nX = ddx(N), nY = ddy(N);

    float2 size;
    tex.GetDimensions(size.x, size.y);
    if (all(size <= 1)) return;   // a solid colour (no texture): no texels to snap to
    float lod = round(tex.CalculateLevelOfDetail(samp, uv));
    size = max(floor(size / exp2(lod)), 1);
    float2 t = uv * size;
    float2 dUV = (floor(t) + 0.5 - t) / size;   // to the texel centre

    // The screen step s with uvX * s.x + uvY * s.y = dUV, by the inverse of [uvX uvY]. Its columns over det,
    // scaled to one texel, are a texel's extent in scene pixels along u and v; compared times |det| so no
    // UVs at all (det 0) skips too.
    float det = uvX.x * uvY.y - uvX.y * uvY.x;
    float texelPixels = max(length(float2(uvY.y, -uvX.y)) / size.x, length(float2(-uvY.x, uvX.x)) / size.y);
    if (texelPixels >= TEXEL_SNAP_MAX_PIXELS * abs(det)) return;
    float2 s = float2(uvY.y * dUV.x - uvY.x * dUV.y, uvX.x * dUV.y - uvX.y * dUV.x) / det;
    pos += posX * s.x + posY * s.y;
    N = normalize(N + nX * s.x + nY * s.y);
}

float4 shade_pixel(VSOut input, bool cutout, bool blended) {
    StructuredBuffer<Material> materialBuffer = DescriptorHandle<StructuredBuffer<Material>>(gFrame.materialBufferSlot);
    Material material = materialBuffer[input.material];

    // Colour textures are sRGB views (decoded on sample), material and vertex colours linear (glTF).
    Texture2D<float4> tex = getTexture2dRGBA(material.colorTex);
    SamplerState samp = getSampler(gFrame.samplerSlot);
    float2 uv = lerp(input.uv0, input.uvAffine, gFrame.affine);
    float4 albedo = tex.Sample(samp, uv) * material.color * input.color;

    // Flat's face normal comes from the position's derivatives, so before any snap moves it.
    float3 pos = input.worldPos;
    float3 N = input.shading == SHADING_FLAT ? face_normal(pos) : normalize(input.normal);   // interpolation de-normalizes it
    if (gFrame.texelLighting != 0) texel_snap(tex, samp, input.uv0, pos, N);
    if (cutout && albedo.a < CUTOUT_ALPHA) discard;

    // The lighting debug views that show light alone light a white surface (Lighting_View in render_view.odin).
    uint lightingView = gFrame.lightingView;
    if (lightingView == LIGHTING_PROBES_ONLY || lightingView == LIGHTING_LIGHTING_ONLY) albedo.rgb = 1;

    VertexLight vertexLight;
    vertexLight.diffuse = input.vertexDiffuse;
    vertexLight.shadowed[0] = input.vertexShadowed0;
    vertexLight.shadowed[1] = input.vertexShadowed1;
    vertexLight.shadowed[2] = input.vertexShadowed2;
    vertexLight.shadowed[3] = input.vertexShadowed3;
    vertexLight.shadowLight = input.vertexShadowLight;
    float3 lit = shade(input.shading, albedo.rgb, pos, N, vertexLight);
    // Alpha 1 = scene coverage: the post pass leaves alpha-0 (background) pixels alone. A blended surface's
    // alpha is its blend weight instead (dx.Blend_Mode), which keeps the coverage of what it's over.
    return float4(lit, blended ? albedo.a : 1);
}

// One entry point per blend: the scene PSOs in render_dx.odin. Alpha and Additive share one and differ in
// the PSO's blend state.
[shader("fragment")]
float4 frag_main(VSOut input) : SV_Target { return shade_pixel(input, false, false); }

[shader("fragment")]
float4 frag_cutout(VSOut input) : SV_Target { return shade_pixel(input, true, false); }

[shader("fragment")]
float4 frag_blend(VSOut input) : SV_Target { return shade_pixel(input, false, true); }
