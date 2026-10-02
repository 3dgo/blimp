module common;

public struct FrameConstants {
    public float4x4 viewMat;
    public float4x4 projMat;
    public float3   cameraPos;
    public uint     lightCount;
    public float    time;
    public uint2    resolution;
    
    public uint     transformBufferSlot;
    public uint     meshInstanceBufferSlot;
    public uint     lightBufferSlot;
    
    public uint     meshBufferSlot;
    public uint     indexBufferSlot;
    public uint     positionBufferSlot;
    public uint     attributeBufferSlot;
    public uint     materialBufferSlot;
    public uint     samplerSlot;

    public uint     debugLineBufferSlot;
}

public ConstantBuffer<FrameConstants> gFrame : register(b0, space0);

public struct Light {
    public float3 position; public uint type;
    public float3 direction; public float radius;
    public float3 color; public float cosCone;
    public float intensity; public float3 _pad;
}

public static const uint LIGHT_DIRECTIONAL = 1;
public static const uint LIGHT_POINT = 2;
public static const uint LIGHT_SPOT = 3;