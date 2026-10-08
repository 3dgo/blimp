module shadow;

import "utils";

// Depth-only shadow map pass (render_shadows.odin): the scene's geometry from one slice's camera. No
// pixel shader. Doesn't import common: its b0 is this pass's constants, not FrameConstants.

// Shadow_View in render_shadows.odin, one per slice, bound as the root CBV for that slice's draws.
struct ShadowConstants {
    float4x4 viewProj;
    uint     transformBufferSlot;
    uint     meshInstanceBufferSlot;
    uint     meshBufferSlot;
    uint     positionBufferSlot;
    uint     skinBufferSlot;
    uint     boneBufferSlot;
    // The Shadow Maps window's pass (frag_debug) only.
    uint     shadowMapSlot;
    uint     slice;
    float    near;
    float    far;   // perspective planes, to show depth linearly; far 0 = orthographic (already linear)
}
ConstantBuffer<ShadowConstants> gShadow : register(b0, space0);

// As in scene.slang (the structured-buffer layouts must match).
struct MeshInstance {
    uint transformIndex;
    uint mesh;
    uint material;
    uint shading;
    float4 tint;
    uint   boneOffset;
    uint3  _pad;
}

struct Mesh {
    uint indexOffset;
    uint indexCount;
    uint vertexOffset;
    uint vertexCount;
    uint material;
    uint skinOffset;   // into the skin buffer, parallel to the vertices; 0xFFFFFFFF = static
    uint2 _pad;
}

struct VSIn {
    uint instanceID    : SV_InstanceID;
    uint startInstance : SV_StartInstanceLocation;
    uint vertexID      : SV_VertexID;
}

[shader("vertex")]
float4 vert_main(VSIn input) : SV_Position {
    StructuredBuffer<MeshInstance> meshInstanceBuffer = DescriptorHandle<StructuredBuffer<MeshInstance>>(gShadow.meshInstanceBufferSlot);
    StructuredBuffer<Mesh>         meshBuffer         = DescriptorHandle<StructuredBuffer<Mesh>>(gShadow.meshBufferSlot);
    StructuredBuffer<float4x4>     transformBuffer    = DescriptorHandle<StructuredBuffer<float4x4>>(gShadow.transformBufferSlot);
    StructuredBuffer<float3>       positionBuffer     = DescriptorHandle<StructuredBuffer<float3>>(gShadow.positionBufferSlot);

    MeshInstance meshInstance = meshInstanceBuffer[input.startInstance + input.instanceID];
    Mesh         mesh         = meshBuffer[meshInstance.mesh];
    float4x4     transform    = transformBuffer[meshInstance.transformIndex];

    float3 localPos = positionBuffer[mesh.vertexOffset + input.vertexID];
    if (mesh.skinOffset != 0xFFFFFFFF && meshInstance.boneOffset != 0xFFFFFFFF) {   // as in scene.slang
        localPos = mul(float4(localPos, 1.0), skinMatrix(gShadow.skinBufferSlot, gShadow.boneBufferSlot, mesh.skinOffset + input.vertexID, meshInstance.boneOffset)).xyz;
    }
    float4 worldPos = mul(float4(localPos, 1.0), transform);
    return mul(worldPos, gShadow.viewProj);
}

// The Shadow Maps window (render_shadows_debug_draw): one slice drawn into its tile of the atlas as grey
// depth, white at the light and black at the far plane; dark blue where nothing casts (still cleared).
static const float SHADOW_DEBUG_TILE = 256;   // SHADOW_DEBUG_TILE in render_shadows.odin

[shader("vertex")]
float4 vert_debug(uint vertexID : SV_VertexID) : SV_Position {
    return fullscreen_triangle(vertexID);   // covers the tile's viewport
}

[shader("fragment")]
float4 frag_debug(float4 pos : SV_Position) : SV_Target {
    Texture2DArray<float> shadowMap = DescriptorHandle<Texture2DArray<float>>(gShadow.shadowMapSlot);
    uint size, height, slices;
    shadowMap.GetDimensions(size, height, slices);
    float2 local = pos.xy - floor(pos.xy / SHADOW_DEBUG_TILE) * SHADOW_DEBUG_TILE;   // SV_Position is in atlas pixels
    float d = shadowMap.Load(int4(int2(local * size / SHADOW_DEBUG_TILE), gShadow.slice, 0));
    if (d <= 0) return float4(0.05, 0.07, 0.14, 1);
    float v = d;   // orthographic: reversed-Z depth is already linear, 1 at the light
    if (gShadow.far > 0) {   // perspective reversed-Z: d = n(f - z) / (z(f - n)), solved for z
        float n = gShadow.near, f = gShadow.far;
        v = 1 - n * f / (d * (f - n) + n) / f;
    }
    return float4(v.xxx, 1);
}
