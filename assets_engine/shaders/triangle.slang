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

    // Blinn-Phong, per pixel, every light in the world.
    float3 lit = albedo.rgb * AMBIENT;
    for (uint i = 0; i < gFrame.lightCount; i++) {
        Light light = lightBuffer[i];
        float3 L;
        float atten = 1;
        if (light.type == LIGHT_DIRECTIONAL) {
            L = -light.direction;   // the light shines along its +Z
        } else {
            float3 toLight = light.position - input.worldPos;
            float d = length(toLight);
            L = toLight / d;
            float f = saturate(1 - d / light.radius);
            atten = f * f;
            if (light.type == LIGHT_SPOT) {
                // Soft rim over the outer 20% of the cone (a fraction, so narrow cones don't overshoot 1).
                atten *= smoothstep(light.cosCone, lerp(light.cosCone, 1, 0.2), dot(-L, light.direction));
            }
        }
        float ndl  = saturate(dot(N, L));
        float3 H   = normalize(L + V);
        float spec = ndl > 0 ? pow(saturate(dot(N, H)), SHININESS) * SPEC_STRENGTH : 0;   // no highlight on the far side
        lit += (albedo.rgb * ndl + spec) * light.color * light.intensity * atten;
    }
    return float4(lit, albedo.a);
}