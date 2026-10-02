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
    public uint     hdrTextureSlot;   // the view's scene target, read by the post pass
    public float    exposure;         // linear multiplier, 2^EV
    public uint     depthTextureSlot; // the view's scene depth (R32_FLOAT), read by passes at the display size
    public uint     sceneScale;       // display pixels per scene pixel, each way
    public uint     dither;           // nonzero: the post pass quantizes to 5 bits per channel with a 4x4 Bayer dither
    public float2   sceneCover;       // the part of the scene target the display covers: display / (sceneScale * scene size)
    public float2   vertexSnap;       // the scene VS rounds NDC xy to steps of 1 / vertexSnap (half the scene size: whole scene pixels); 0 = off
    public float    affine;           // 0 = perspective-correct UVs, 1 = affine (PS1 texture warp); in between blends

    public uint     probeBufferSlot;  // baked probes (render_probes.odin); probeDims 0 = not baked
    public float3   probeOrigin;
    public float    probeSpacing;
    public uint3    probeDims;
    public uint     lightingView;     // Lighting_View (render_view.odin): LIGHTING_* below
    public float    indirectScale;    // × indirect light
    public uint     probeLayers;      // probe buffer layers: static, then one per lit light group
    public uint2    _padLayers;
    public float4   probeLayerScale[2];   // layer k's light-group scale at [k / 4][k % 4]

    public uint     shadowMapSlot;        // the world's shadow map slices (Texture2DArray, render_shadows.odin)
    public uint     shadowViewBufferSlot; // ShadowView per slice
    public uint2    _padShadow;
}

public ConstantBuffer<FrameConstants> gFrame : register(b0, space0);

public struct Light {
    public float3 position; public uint type;
    public float3 direction; public float radius;
    public float3 color; public float cosOuter;
    public float intensity; public float cosInner; public float innerRadius; public uint falloff;
    public float beamRadius; public float beamInner; public uint shadowSlice; public float shadowTexel;
}

// Light.shadowSlice of a light without a shadow map (SHADOW_NONE), and the slices' size (SHADOW_MAP_SIZE).
public static const uint SHADOW_NONE = 0xFFFFFFFF;
public static const uint SHADOW_MAP_SIZE = 512;

// FrameConstants.lightingView
public static const uint LIGHTING_LIT = 0;
public static const uint LIGHTING_PROBES_ONLY = 1;
public static const uint LIGHTING_INDIRECT_ONLY = 2;
public static const uint LIGHTING_DIRECT_ONLY = 3;
public static const uint LIGHTING_LIGHTING_ONLY = 4;

public static const uint LIGHT_DIRECTIONAL = 1;
public static const uint LIGHT_POINT = 2;
public static const uint LIGHT_SPOT = 3;
public static const uint LIGHT_CYLINDER = 4;

// Light.falloff (EntityLightFalloff)
public static const uint FALLOFF_INVERSE_SQUARE = 0;
public static const uint FALLOFF_LINEAR = 1;
public static const uint FALLOFF_SMOOTH = 2;