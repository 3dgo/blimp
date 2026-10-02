module vertex;

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
    output.position = mul(mul(worldPos, gFrame.viewMat), gFrame.projMat);
    output.worldPos = worldPos.xyz;
    output.color = attributeBuffer[vertexIndex].color;
    output.normal = mul(attributeBuffer[vertexIndex].normal, cofactor) * flip;
    output.uv0 = attributeBuffer[vertexIndex].uv0;
    output.material = meshInstance.material;
    return output;
}

static const float3 AMBIENT       = 0.08;   // stands in for the baked probes until the baker exists
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

[shader("fragment")]
float4 frag_main(VSOut input) : SV_Target {
    StructuredBuffer<Material> materialBuffer = DescriptorHandle<StructuredBuffer<Material>>(gFrame.materialBufferSlot);
    StructuredBuffer<Light>    lightBuffer    = DescriptorHandle<StructuredBuffer<Light>>(gFrame.lightBufferSlot);
    Material material = materialBuffer[input.material];

    Texture2D<float4> tex = getTexture2dRGBA(material.colorTex);
    SamplerState samp = getSampler(gFrame.samplerSlot);
    float4 albedo = tex.Sample(samp, input.uv0) * material.color * input.color;

    float3 N = normalize(input.normal);   // interpolation de-normalizes it
    float3 V = normalize(gFrame.cameraPos - input.worldPos);

    // Blinn-Phong, per pixel, every light in the world. Everything here is linear: colour textures are
    // sRGB views (decoded on sample), material and vertex colours are linear (glTF), and the output goes
    // to a float target that the tonemap pass encodes for display.
    float3 lit = albedo.rgb * AMBIENT;
    for (uint i = 0; i < gFrame.lightCount; i++) {
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
        float3 H   = normalize(L + V);
        float spec = ndl > 0 ? pow(saturate(dot(N, H)), SHININESS) * SPEC_STRENGTH : 0;   // no highlight on the far side
        lit += (albedo.rgb * ndl + spec) * light.color * light.intensity * atten;
    }
    return float4(lit, 1);   // alpha 1 = scene coverage: the tonemap leaves alpha-0 (background) pixels alone
}