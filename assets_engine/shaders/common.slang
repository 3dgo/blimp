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
    public uint     hdrTextureSlot;   // the view's scene target, read by the tonemap pass
    public float    exposure;         // linear multiplier, 2^EV
}

public ConstantBuffer<FrameConstants> gFrame : register(b0, space0);

public struct Light {
    public float3 position; public uint type;
    public float3 direction; public float radius;
    public float3 color; public float cosOuter;
    public float intensity; public float cosInner; public float innerRadius; public uint falloff;
    public float beamRadius; public float beamInner; public float2 _pad;
}

public static const uint LIGHT_DIRECTIONAL = 1;
public static const uint LIGHT_POINT = 2;
public static const uint LIGHT_SPOT = 3;
public static const uint LIGHT_CYLINDER = 4;

// Light.falloff (EntityLightFalloff)
public static const uint FALLOFF_INVERSE_SQUARE = 0;
public static const uint FALLOFF_LINEAR = 1;
public static const uint FALLOFF_SMOOTH = 2;