module debug_line;

import "utils";
import "common";

public struct DebugLineVertex {
    public float4 pos;
    public float4 color;
}

public struct VSOut {
    public float4 position : SV_Position;
    public float4 color : COLOR;
}

public struct VSIn {
    uint vertexID    : SV_VertexID;              // 0-based within the draw — does NOT include StartVertexLocation
    uint startVertex : SV_StartVertexLocation;   // each view draws its own range of the shared line list
}

[shader("vertex")]
public VSOut vert_main(VSIn input) {
    StructuredBuffer<DebugLineVertex> lines = DescriptorHandle<StructuredBuffer<DebugLineVertex>>(gFrame.debugLineBufferSlot);
    DebugLineVertex v = lines[input.startVertex + input.vertexID];
    float4x4 vp = mul(gFrame.viewMat, gFrame.projMat);
    VSOut o;
    o.position = mul(v.pos, vp);
    o.color = v.color;
    return o;
}

[shader("fragment")]
float4 frag_main(VSOut input) : SV_Target {
    // Depth-tested by hand: lines draw at the display size, the scene's depth is at the scene size, so it
    // can't be bound as the DSV. Same test the PSO would do (reversed-Z GREATER_EQUAL) against the scene
    // pixel this one sits in.
    Texture2D<float> depth = getTexture2dF1(gFrame.depthTextureSlot);
    float scene = depth.Load(int3(uint2(input.position.xy) / gFrame.sceneScale, 0));
    if (input.position.z < scene) discard;
    return input.color;
}

// Lines that show through everything: the collision view, whose shapes are usually inside the model.
[shader("fragment")]
float4 frag_top(VSOut input) : SV_Target { return input.color; }
