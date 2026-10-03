module shadow;

// Depth-only shadow map pass (render_shadows.odin): the scene's geometry from one slice's camera. No
// pixel shader. Doesn't import common: its b0 is this pass's constants, not FrameConstants.

// Shadow_View in render_shadows.odin, one per slice, bound as the root CBV for that slice's draws.
struct ShadowConstants {
    float4x4 viewProj;
    uint     transformBufferSlot;
    uint     meshInstanceBufferSlot;
    uint     meshBufferSlot;
    uint     positionBufferSlot;
}
ConstantBuffer<ShadowConstants> gShadow : register(b0, space0);

// As in scene.slang (the structured-buffer layouts must match).
struct MeshInstance {
    uint transformIndex;
    uint mesh;
    uint material;
    uint shading;
    float4 tint;
}

struct Mesh {
    uint indexOffset;
    uint indexCount;
    uint vertexOffset;
    uint vertexCount;
    uint material;
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

    float4 worldPos = mul(float4(positionBuffer[mesh.vertexOffset + input.vertexID], 1.0), transform);
    return mul(worldPos, gShadow.viewProj);
}
