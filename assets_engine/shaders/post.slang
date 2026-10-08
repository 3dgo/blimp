module post;

import "utils";
import "common";
import "shading";
import "view";

// The post chain (claude/rendering.md: tonemap → LUT → quantize + dither → upscale), fullscreen triangles
// (render_post.odin). A retro view:
//   frag_signal   scene size: the HDR scene target → the signal (tonemapped, quantized + dithered,
//                 display-space)
//   frag_upscale  display size: the signal → the display target, point-sampled
// A clean view runs frag_signal alone, straight into the display target (same size, nothing quantized).
// Each frag_* reads whole scene pixels with Load.
// No LUT yet.

public struct VSOut {
    public float4 position : SV_Position;
}

[shader("vertex")]
public VSOut vert_main(uint vertexID : SV_VertexID) {
    VSOut o;
    o.position = fullscreen_triangle(vertexID);
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

// Display-space colour → colorLevels + 1 levels per channel, ordered-dithered at scene pixel `px`, the
// threshold spread scaled by `dither` (0 = plain rounding: banding). Display space, not linear: these
// scenes sit low in the value range, where linear quantizing has almost no levels.
float3 quantize_dither(float3 c, uint2 px) {
    float t = 0.5 + (bayer4(px) - 0.5) * gFrame.dither;
    return floor(c * gFrame.colorLevels + t) / gFrame.colorLevels;
}

// ------------------------------------------------------------------------------------------------------
// Fog (World_Settings.fog, claude/rendering.md → Fog), along each scene pixel's ray from the near plane to the
// scene depth, in scene light before the tonemap:
//     scene × T + the fogs' colours × (1 − T) + halos
// T, the transmittance, is the distance fog's ramp times the height fog's exp(-optical depth), both closed form.
// The background is a pixel like any other (depth 0: the ray never hit anything). Blended surfaces don't write
// depth: they take the fog of what's behind them.

static const float FOG_OPAQUE    = 100;   // optical depth: nothing gets through (e^-100)
static const float FOG_LIT_REACH = 64;    // lit height fog samples the probes this far along a ray at most
static const uint  FOG_LIT_STEPS = 6;
static const uint  HALO_STEPS    = 12;

bool fog_on() {
    return gFrame.fogEnd > gFrame.fogStart || gFrame.fogDensity > 0 || gFrame.fogGlow > 0;
}

// Height fog's density (per metre) at world height y.
float fog_height_density(float y) {
    if (gFrame.fogDensity <= 0) return 0;
    return gFrame.fogDensity * exp(clamp((gFrame.fogHeight - y) / gFrame.fogFalloff, -80, 80));
}

// Height fog's optical depth over the first t metres of r: the density's integral, closed form for an
// exponential. x is how many falloffs the ray climbs; clamped below, and the result capped at FOG_OPAQUE, so a
// long ray down stays finite (an infinite depth turns the colour mix in fog_inscatter into NaN).
float fog_height_depth(ViewRay r, float t) {
    if (gFrame.fogDensity <= 0) return 0;
    float x = max(r.dir.y * t / gFrame.fogFalloff, -80);
    float s = abs(x) > 1e-4 ? (1 - exp(-x)) / x : 1 - 0.5 * x;
    return min(fog_height_density(r.origin.y) * min(t * s, 1e30), FOG_OPAQUE);
}

// Distance fog's transmittance t metres along the ray: the PS1 ramp, 1 nearer than fogStart, 0 from fogEnd.
float fog_distance_transmittance(float t) {
    if (gFrame.fogEnd <= gFrame.fogStart) return 1;
    return 1 - saturate((t - gFrame.fogStart) / (gFrame.fogEnd - gFrame.fogStart));
}

// How much of what's t metres along r reaches the eye: 1 = clear.
float fog_transmittance(ViewRay r, float t) {
    return fog_distance_transmittance(t) * exp(-fog_height_depth(r, t));
}

// Lit fog's light at world point p: the probes' light in the air over the level's average, per channel, so
// the picked colour shows where the light is average. Where no probe sees p (under the ground, past the grid)
// it fades to 1, the picked colour, rather than the dark of buried probes.
float3 fog_lit_scale(float3 p) {
    float seen;
    float3 light = air_light(p, seen);
    return lerp(1, light / max(gFrame.fogLightMean, 1e-4), seen);
}

// The colour the fog adds along r, and in T its transmittance over the whole ray: (1 - T) of the two fogs'
// colours, mixed by each one's share of the ray's optical depth (the distance ramp's is -ln of its
// transmittance), so whichever fog is thicker along this ray shows its colour.
// Lit fog (fogLit) scales that by the light along the ray, summed over FOG_LIT_STEPS stretches from where the
// fog begins to fogEnd (or FOG_LIT_REACH), each weighted by the fog it holds (the drop in transmittance across
// it); the fog beyond takes the last stretch's light. The samples are offset by the pixel's Bayer threshold, so
// the steps between them break up like the dither.
float3 fog_inscatter(ViewRay r, uint2 px, out float T) {
    float distanceT = fog_distance_transmittance(r.len);
    float heightDepth = fog_height_depth(r, r.len);
    T = distanceT * exp(-heightDepth);
    if (T == 1) return 0;
    float distanceDepth = -log(max(distanceT, 1e-6));
    float3 color = (distanceDepth * gFrame.fogDistanceColor + heightDepth * gFrame.fogHeightColor) / (distanceDepth + heightDepth);
    if (gFrame.fogLit <= 0) return color * (1 - T);

    bool  distance = gFrame.fogEnd > gFrame.fogStart;
    float a = gFrame.fogDensity > 0 || !distance ? 0 : gFrame.fogStart;
    float b = min(r.len, distance ? gFrame.fogEnd : FOG_LIT_REACH);
    float offset = bayer4(px);
    float prev = fog_transmittance(r, a);
    float3 lit = 0, scale = 1;
    for (uint k = 0; k < FOG_LIT_STEPS; k++) {
        float Tk = fog_transmittance(r, lerp(a, b, float(k + 1) / FOG_LIT_STEPS));
        scale = fog_lit_scale(r.origin + r.dir * lerp(a, b, (k + offset) / FOG_LIT_STEPS));
        lit += (prev - Tk) * scale;
        prev = Tk;
    }
    lit += (prev - T) * scale;
    return color * lerp(1 - T, lit, gFrame.fogLit);
}

// Lamp light the fog scatters toward the eye along r. For each point and spot light, over the part of the ray
// inside its range: the light reaching each point (light_reach: the falloff and cone surfaces get) × the haze
// there (fogGlow + the height fog's density) × the transmittance back to the eye × the light's halo, spread
// evenly over directions (÷ 4: the engine's lights carry no 1/π, so neither does this).
// HALO_STEPS equiangular steps (Kulla & Fajardo 2012): even in the angle seen from the light, which cancels the
// 1/d², so a ray past the bulb needs no more steps than one far off. Each pixel's steps are offset by its Bayer
// threshold, so what's left of the stepping is an ordered pattern, like the dither. The ray stops at the scene
// surface, so a wall in front cuts a halo off; but there are no shadows yet, so within its range a lamp behind
// a wall lights the air on this side.
float3 fog_halos(ViewRay r, uint2 px) {
    if (gFrame.fogGlow <= 0 || !view_direct()) return 0;
    StructuredBuffer<Light> lights = DescriptorHandle<StructuredBuffer<Light>>(gFrame.lightBufferSlot);
    float offset = bayer4(px);
    float3 sum = 0;
    for (uint i = 0; i < gFrame.lightCount; i++) {
        Light light = lights[i];
        if ((light.type != LIGHT_POINT && light.type != LIGHT_SPOT) || light.halo <= 0) continue;
        float3 toLight = light.position - r.origin;
        float  t0 = dot(toLight, r.dir);            // the ray's closest approach to the light
        float  h  = length(toLight - r.dir * t0);   // and how close
        if (h >= light.radius) continue;
        float  c = sqrt(light.radius * light.radius - h * h);
        float  a = max(t0 - c, 0), b = min(t0 + c, r.len);
        if (a >= b) continue;
        // The steps' scale: at least the source's size, so they don't bunch up when the ray goes through the bulb.
        float  hs  = max(h, max(light.innerRadius, 0.01));
        float  thA = atan((a - t0) / hs), thB = atan((b - t0) / hs);
        float  acc = 0;
        for (uint k = 0; k < HALO_STEPS; k++) {
            float  s = hs * tan(lerp(thA, thB, (k + offset) / HALO_STEPS));
            float3 p = r.origin + r.dir * (t0 + s);
            float3 L;
            float  haze = gFrame.fogGlow + fog_height_density(p.y);
            acc += light_reach(light, p, L) * (hs * hs + s * s) * haze * fog_transmittance(r, t0 + s);
        }
        sum += light.color * light.intensity * light.halo * acc * (thB - thA) / (HALO_STEPS * hs);
    }
    return sum * 0.25;
}

// Display-space colour of scene pixel `px`: fog, exposure, the tonemap and the quantize + dither. Every pixel
// takes the same path, the background (the clear colour, linear scene light) included.
[shader("fragment")]
float4 frag_signal(VSOut input) : SV_Target {
    Texture2D<float4> hdr = getTexture2dRGBA(gFrame.hdrTextureSlot);
    uint2 px = uint2(input.position.xy);
    float3 light = max(hdr.Load(int3(px, 0)).rgb, 0);
    if (fog_on()) {
        ViewRay r = view_ray(px);
        float T;
        float3 add = fog_inscatter(r, px, T) + fog_halos(r, px);
        light = light * T + add;
    }
    float3 c = linear_to_srgb(aces_fitted(light * gFrame.exposure));
    if (gFrame.colorLevels > 0) c = quantize_dither(c, px);
    return float4(c, 1);
}

// The signal, point-sampled up to the display size.
[shader("fragment")]
float4 frag_upscale(VSOut input) : SV_Target {
    Texture2D<float4> signal = getTexture2dRGBA(gFrame.signalTextureSlot);
    uint2 px = uint2(input.position.xy) / gFrame.sceneScale;   // the scene pixel this display pixel sits in
    return float4(signal.Load(int3(px, 0)).rgb, 1);
}
