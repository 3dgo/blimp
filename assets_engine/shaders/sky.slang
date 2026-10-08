module sky;

import "utils";
import "common";
import "view";

// The sky (World_Settings.sky, claude/rendering.md → Sky): one fullscreen triangle into the scene target, before
// the opaques, writing the panorama's linear light. No depth test or write: the depth stays the clear's 0, so the
// post pass fogs it as a ray that hit nothing.

struct VSOut {
    float4 position : SV_Position;
}

[shader("vertex")]
VSOut vert_main(uint vertexID: SV_VertexID) {
    VSOut o;
    o.position = fullscreen_triangle(vertexID);
    return o;
}

// The world direction through this pixel → the panorama: u is the angle around +Y (0.5 = +Z, increasing toward
// +X, then turned by skyRotation), v the angle down from straight up (0 = up, 1 = down). Equirectangular 2:1.
// SampleLevel, not Sample: u jumps from 1 to 0 behind the camera, and with derivatives that seam would pick the
// smallest mip and draw a line.
[shader("fragment")]
float4 frag_main(VSOut input) : SV_Target {
    float3 dir = view_ray_dir(scene_ndc(uint2(input.position.xy)));
    float2 uv = float2(atan2(dir.x, dir.z) / (2 * PI) + 0.5 - gFrame.skyRotation, acos(clamp(dir.y, -1, 1)) / PI);
    float3 c = getTexture2dRGBA(gFrame.skyTextureSlot).SampleLevel(getSampler(gFrame.samplerSlot), uv, 0).rgb;
    return float4(c * gFrame.skyIntensity, 1);
}