module tonemap;

import "utils";
import "common";

// Head of the post chain (docs/rendering.md: tonemap → LUT → quantize + dither → upscale): the view's
// linear HDR scene target → its display target, which ImGui samples as-is. One fullscreen triangle.

public struct VSOut {
    public float4 position : SV_Position;
}

[shader("vertex")]
public VSOut vert_main(uint vertexID : SV_VertexID) {
    float2 uv = float2((vertexID << 1) & 2, vertexID & 2);   // (0,0) (2,0) (0,2): covers the screen
    VSOut o;
    o.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return o;
}

// ACES filmic, Stephen Hill's fit of the RRT + ODT (as in Unreal's filmic tonemapper and Unity's ACES
// option). Input and output are linear Rec.709.
static const float3x3 ACES_INPUT = float3x3(
    0.59719, 0.35458, 0.04823,
    0.07600, 0.90834, 0.01566,
    0.02840, 0.13383, 0.83777);
static const float3x3 ACES_OUTPUT = float3x3(
     1.60475, -0.53108, -0.07367,
    -0.10208,  1.10813, -0.00605,
    -0.00327, -0.07276,  1.07602);

float3 aces_fitted(float3 c) {
    c = mul(ACES_INPUT, c);
    c = (c * (c + 0.0245786) - 0.000090537) / (c * (0.983729 * c + 0.4329510) + 0.238081);
    return saturate(mul(ACES_OUTPUT, c));
}

float3 linear_to_srgb(float3 c) {
    return select(c <= 0.0031308, c * 12.92, 1.055 * pow(c, 1.0 / 2.4) - 0.055);
}

[shader("fragment")]
float4 frag_main(VSOut input) : SV_Target {
    Texture2D<float4> hdr = getTexture2dRGBA(gFrame.hdrTextureSlot);
    float4 s = hdr.Load(int3(int2(input.position.xy), 0));   // same size as the target: no sampler
    // Alpha 0 is the background, which was cleared to the world's display-space (sRGB) colour: shown as
    // picked, untouched by exposure and the tonemap. The scene writes alpha 1.
    if (s.a == 0) return float4(s.rgb, 1);
    float3 c = aces_fitted(max(s.rgb, 0) * gFrame.exposure);
    return float4(linear_to_srgb(c), 1);
}
