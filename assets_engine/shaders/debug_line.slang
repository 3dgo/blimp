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
    return input.color;
}