module common;

public struct FrameConstants {
    public float4x4 viewMat;
    public float4x4 projMat;
    public float3   cameraPos;
    public uint     lightCount;
    
    public uint     transformBufferSlot;
    public uint     meshInstanceBufferSlot;
    public uint     lightBufferSlot;
    
    public uint     meshBufferSlot;
    public uint     positionBufferSlot;
    public uint     attributeBufferSlot;
    public uint     materialBufferSlot;
    public uint     samplerSlot;

    public uint     debugLineBufferSlot;
    public uint     hdrTextureSlot;   // the view's scene target, read by the post pass
    public float    exposure;         // linear multiplier, 2^EV
    public uint     depthTextureSlot; // the view's scene depth (R32_FLOAT), read by passes at the display size
    public uint     sceneScale;       // display pixels per scene pixel, each way
    public float    colorLevels;      // the post chain quantizes each channel to 0..colorLevels (2^bits - 1); 0 = off
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
    public uint     probeDepthSlot;   // one ProbeDepth per probe (the visibility test)
    public uint     _padLayers;
    public float4   probeLayerScale[2];   // layer k's light-group scale at [k / 4][k % 4]

    public uint     shadowMapSlot;        // the world's shadow map slices (Texture2DArray, render_shadows.odin)
    public uint     shadowViewBufferSlot; // ShadowView per slice

    // The retro post chain (render_post.odin, post.slang): its scene-size intermediates, and the effects'
    // amounts from Retro_Settings, each 0 when its effect is off.
    public uint     signalTextureSlot;    // the signal: tonemapped, quantized, display-space
    public uint     bloomTextureSlot;     // the bloom blurred across
    public uint     bloomOutTextureSlot;  // then down: what the upscale adds
    public uint     crt;                  // nonzero: the upscale is a CRT's (else point-sampled)
    public float    dither;               // Bayer threshold spread, 0..1
    public float    lumaBlur;
    public float    chromaBlur;
    public float    scanlines;            // beam profile strength
    public float    beamDark;
    public float    beamBright;
    public float    mask;
    public float    bloom;
    public float    bloomRadius;
    public float    gamma;
    public float    brightness;

    public float3   fogColor;         // distance fog (World_Settings.fog): the background colour, display space
    public float    fogStart;         // metres from the eye: full colour nearer
    public float    fogEnd;           // all fog colour from here; <= fogStart: fog off
    public float2   _padFog;
    public float4x4 invProj;          // this view's projection, inverted: scene depth -> view space
    public uint     skinBufferSlot;   // SkinVertex per skinned vertex (Mesh.skinOffset)
    public uint     boneBufferSlot;   // the world's skin matrices this frame (MeshInstance.boneOffset)
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