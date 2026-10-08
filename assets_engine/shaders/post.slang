module post;

import "utils";
import "common";
import "shading";

// The post chain (claude/rendering.md: tonemap → LUT → quantize + dither → upscale), fullscreen triangles
// (render_post.odin). A retro view:
//   frag_signal   scene size: the HDR scene target → the signal (tonemapped, quantized + dithered,
//                 display-space): what the PS1 sent the TV
//   frag_bloom_h  scene size, CRT bloom only: the signal as light, blurred across
//   frag_bloom_v                                and down
//   frag_upscale  display size: the signal → the display target, point-sampled, or as a CRT shows it
// A clean view runs frag_signal alone, straight into the display target (same size, nothing quantized).
// Each frag_* reads whole scene pixels with Load: the upscale reconstructs from raw pixels itself.
// No LUT yet.

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

// 4x4 Bayer thresholds, (n + 0.5) / 16: added before the floor, they spread each value over its two
// nearest levels in the right proportion.
static const float BAYER_4X4[16] = {
     0.5 / 16,  8.5 / 16,  2.5 / 16, 10.5 / 16,
    12.5 / 16,  4.5 / 16, 14.5 / 16,  6.5 / 16,
     3.5 / 16, 11.5 / 16,  1.5 / 16,  9.5 / 16,
    15.5 / 16,  7.5 / 16, 13.5 / 16,  5.5 / 16,
};

// Display-space colour → colorLevels + 1 levels per channel, ordered-dithered at scene pixel `px`, the
// threshold spread scaled by `dither` (0 = plain rounding: banding). Display space, not linear: these
// scenes sit low in the value range, where linear quantizing has almost no levels.
float3 quantize_dither(float3 c, uint2 px) {
    float t = 0.5 + (BAYER_4X4[(px.y & 3) * 4 + (px.x & 3)] - 0.5) * gFrame.dither;
    return floor(c * gFrame.colorLevels + t) / gFrame.colorLevels;
}

// ------------------------------------------------------------------------------------------------------
// Fog (World_Settings.fog, claude/rendering.md → Fog), along each scene pixel's ray from the near plane to the
// scene depth, in scene light before the tonemap:
//     scene × T + the fogs' colours × (1 − T) + halos
// T, the transmittance, is the distance fog's ramp times the height fog's exp(-optical depth), both closed form.
// The background is a pixel like any other (depth 0: the ray never hit anything). Blended surfaces don't write
// depth: they take the fog of what's behind them.

static const float FOG_INFINITY  = 1e6;   // the length of a ray that hit nothing, metres
static const float FOG_OPAQUE    = 100;   // optical depth: nothing gets through (e^-100)
static const float FOG_LIT_REACH = 64;    // lit height fog samples the probes this far along a ray at most
static const uint  FOG_LIT_STEPS = 6;
static const uint  HALO_STEPS    = 12;

bool fog_on() {
    return gFrame.fogEnd > gFrame.fogStart || gFrame.fogDensity > 0 || gFrame.fogGlow > 0;
}

struct FogRay {
    float3 origin;   // world space, on the near plane
    float3 dir;
    float  len;      // metres to the scene surface; FOG_INFINITY where nothing was drawn
}

float3 view_pos(float2 ndc, float depth) {
    float4 v = mul(float4(ndc, depth, 1), gFrame.invProj);
    return v.xyz / v.w;
}

// View space → world space directions: the view matrix is rigid, so its inverse rotation is its transpose.
float3 world_dir(float3 v) {
    float3x3 R = float3x3(gFrame.viewMat[0].xyz, gFrame.viewMat[1].xyz, gFrame.viewMat[2].xyz);
    return mul(R, v);
}

// Scene pixel px's ray, through the inverse projection, so perspective and ortho cameras alike. The scene VS
// squeezed NDC into the target's sceneCover part, so that's undone first. Depth 0 (the reversed-Z clear): the
// ray hit nothing, and with an infinite projection unprojecting it would divide by zero.
FogRay fog_ray(uint2 px) {
    Texture2D<float> depthTex = getTexture2dF1(gFrame.depthTextureSlot);
    uint w, h;
    depthTex.GetDimensions(w, h);
    float2 uv = (float2(px) + 0.5) / float2(w, h);
    float2 ndc = float2(uv.x * 2 - 1, 1 - uv.y * 2);
    float2 cover = gFrame.sceneCover;
    ndc = float2((ndc.x - (cover.x - 1)) / cover.x, (ndc.y - (1 - cover.y)) / cover.y);
    float3 nearV = view_pos(ndc, 1);   // reversed-Z: 1 is the near plane
    FogRay r;
    r.origin = gFrame.cameraPos + world_dir(nearV);
    r.dir    = normalize(world_dir(view_pos(ndc, 0.5) - nearV));
    float depth = depthTex.Load(int3(px, 0));
    r.len    = depth == 0 ? FOG_INFINITY : length(view_pos(ndc, depth) - nearV);
    return r;
}

// Height fog's density (per metre) at world height y.
float fog_height_density(float y) {
    if (gFrame.fogDensity <= 0) return 0;
    return gFrame.fogDensity * exp(clamp((gFrame.fogHeight - y) / gFrame.fogFalloff, -80, 80));
}

// Height fog's optical depth over the first t metres of r: the density's integral, closed form for an
// exponential. x is how many falloffs the ray climbs; clamped below, and the result capped at FOG_OPAQUE, so a
// long ray down stays finite (an infinite depth turns the colour mix in fog_inscatter into NaN).
float fog_height_depth(FogRay r, float t) {
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
float fog_transmittance(FogRay r, float t) {
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
float3 fog_inscatter(FogRay r, uint2 px, out float T) {
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
    float offset = BAYER_4X4[(px.y & 3) * 4 + (px.x & 3)];
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
float3 fog_halos(FogRay r, uint2 px) {
    if (gFrame.fogGlow <= 0 || !view_direct()) return 0;
    StructuredBuffer<Light> lights = DescriptorHandle<StructuredBuffer<Light>>(gFrame.lightBufferSlot);
    float offset = BAYER_4X4[(px.y & 3) * 4 + (px.x & 3)];
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
        FogRay r = fog_ray(px);
        float T;
        float3 add = fog_inscatter(r, px, T) + fog_halos(r, px);
        light = light * T + add;
    }
    float3 c = linear_to_srgb(aces_fitted(light * gFrame.exposure));
    if (gFrame.colorLevels > 0) c = quantize_dither(c, px);
    return float4(c, 1);
}

// CRT bloom: the glass's glow, a wide Gaussian (sigma bloomRadius scene pixels) of the light the tube
// gives off (the signal at CRT gamma), done across then down at the scene size.
static const int BLOOM_MAX_TAPS = 48;   // each side: 3 sigma at the window's largest radius

float3 bloom_blur(Texture2D<float4> src, int2 px, int2 dir, bool decode) {
    uint width, height;
    src.GetDimensions(width, height);
    float sigma = max(gFrame.bloomRadius, 0.5);
    int taps = min(int(ceil(3 * sigma)), BLOOM_MAX_TAPS);
    float3 sum = 0;
    float wsum = 0;
    for (int i = -taps; i <= taps; i++) {
        float3 c = src.Load(int3(clamp(px + dir * i, int2(0, 0), int2(width, height) - 1), 0)).rgb;
        if (decode) c = pow(c, gFrame.gamma);   // signal → light
        float w = exp(-0.5 * float(i * i) / (sigma * sigma));
        sum  += w * c;
        wsum += w;
    }
    return sum / wsum;
}

[shader("fragment")]
float4 frag_bloom_h(VSOut input) : SV_Target {
    return float4(bloom_blur(getTexture2dRGBA(gFrame.signalTextureSlot), int2(input.position.xy), int2(1, 0), true), 1);
}

[shader("fragment")]
float4 frag_bloom_v(VSOut input) : SV_Target {
    return float4(bloom_blur(getTexture2dRGBA(gFrame.bloomTextureSlot), int2(input.position.xy), int2(0, 1), false), 1);
}

// CRT: the signal as a composite TV shows it, reconstructed per display pixel from the raw signal pixels.
// Each effect is skipped at 0 (render_view_update_constants zeroes the ones that are off).
//   1. Composite bandwidth (lumaBlur, chromaBlur): each scanline is low-passed horizontally only (a TV is
//      band-limited along the line, not between lines), in YIQ so luma and chroma get their own
//      bandwidth. This is what melts the dither; the narrower chroma bleeds colour sideways.
//   2. Scanlines (scanlines, beamDark, beamBright): each line is a vertical Gaussian whose width grows
//      with brightness, so bright lines merge and dark ones part into gaps. Area-normalized, so average
//      brightness is kept; the strength blends from flat lines to the full profile.
//   3. Aperture grille (mask): RGB stripes at display pixels, averaging 1.
//   4. Bloom (bloom): the blurred light (frag_bloom_*), added on top, as the glass scatters it.
// The signal decodes to light at the tube's gamma and re-encodes at 2.2, so gamma 2.2 is neutral.
// Distances are in scene pixels (lines, vertically).
static const int   CRT_MAX_TAPS = 12;   // each side of the line blur: 2.5 sigma, up to the window's largest
static const float CRT_MIN_SIGMA = 0.05;
static const float SQRT_2PI = 2.50663;

static const float3x3 RGB_TO_YIQ = float3x3(
    0.299,     0.587,     0.114,
    0.595716, -0.274453, -0.321263,
    0.211456, -0.522591,  0.311135);
static const float3x3 YIQ_TO_RGB = float3x3(
    1,  0.9563,  0.6210,
    1, -0.2721, -0.6474,
    1, -1.1070,  1.7046);

// Scanline `line`'s signal at continuous scene x, after the composite low-pass.
float3 crt_line(Texture2D<float4> signal, int line, float x, int width) {
    float widest = max(gFrame.lumaBlur, gFrame.chromaBlur);
    if (widest == 0) return signal.Load(int3(clamp(int(x), 0, width - 1), line, 0)).rgb;
    float3 sigma = max(float3(gFrame.lumaBlur, gFrame.chromaBlur, gFrame.chromaBlur), CRT_MIN_SIGMA);
    int taps = min(int(ceil(2.5 * widest)), CRT_MAX_TAPS);
    int x0 = int(floor(x));
    float3 sum = 0, wsum = 0;
    for (int i = -taps; i <= taps; i++) {
        float  d = float(x0 + i) + 0.5 - x;
        float3 w = exp(-0.5 * d * d / (sigma * sigma));
        sum  += w * mul(RGB_TO_YIQ, signal.Load(int3(clamp(x0 + i, 0, width - 1), line, 0)).rgb);
        wsum += w;
    }
    return saturate(mul(YIQ_TO_RGB, sum / wsum));
}

// Bilinear `t` at continuous texel position `p` (texel centres at whole + 0.5), clamped at the edges.
float3 load_bilinear(Texture2D<float4> t, float2 p, int2 size) {
    float2 q = p - 0.5;
    int2   i = int2(floor(q));
    float2 f = q - float2(i);
    int2  hi = size - 1;
    float3 a = t.Load(int3(clamp(i,              int2(0, 0), hi), 0)).rgb;
    float3 b = t.Load(int3(clamp(i + int2(1, 0), int2(0, 0), hi), 0)).rgb;
    float3 c = t.Load(int3(clamp(i + int2(0, 1), int2(0, 0), hi), 0)).rgb;
    float3 d = t.Load(int3(clamp(i + int2(1, 1), int2(0, 0), hi), 0)).rgb;
    return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
}

// The display colour at display position `pos` (a pixel centre).
float3 crt(Texture2D<float4> signal, float2 pos) {
    uint width, height;
    signal.GetDimensions(width, height);
    float2 p = pos / gFrame.sceneScale;   // continuous scene position
    int nearest = clamp(int(p.y), 0, int(height) - 1);
    float3 light;
    if (gFrame.scanlines == 0) {
        light = pow(crt_line(signal, nearest, p.x, int(width)), gFrame.gamma);
    } else {
        float3 flat = 0, beams = 0;
        for (int k = -1; k <= 1; k++) {   // the nearest line and one each side: a wide beam reaches ~1.5 lines
            int line = nearest + k;
            if (line < 0 || line >= int(height)) continue;
            float3 s = crt_line(signal, line, p.x, int(width));
            float3 l = pow(s, gFrame.gamma);
            if (k == 0) flat = l;
            float3 sigma = max(lerp(gFrame.beamDark, gFrame.beamBright, s), CRT_MIN_SIGMA);
            float  d     = p.y - (float(line) + 0.5);
            beams += l * exp(-0.5 * d * d / (sigma * sigma)) / (sigma * SQRT_2PI);
        }
        light = lerp(flat, beams, gFrame.scanlines);
    }
    if (gFrame.mask > 0) {
        float3 m = 1 - gFrame.mask;
        m[uint(pos.x) % 3] = 1 + 2 * gFrame.mask;
        light *= m;
    }
    if (gFrame.bloom > 0) {
        light += gFrame.bloom * load_bilinear(getTexture2dRGBA(gFrame.bloomOutTextureSlot), p, int2(width, height));
    }
    return pow(saturate(light * gFrame.brightness), 1.0 / 2.2);
}

[shader("fragment")]
float4 frag_upscale(VSOut input) : SV_Target {
    Texture2D<float4> signal = getTexture2dRGBA(gFrame.signalTextureSlot);
    if (gFrame.crt != 0) return float4(crt(signal, input.position.xy), 1);
    uint2 px = uint2(input.position.xy) / gFrame.sceneScale;   // the scene pixel this display pixel sits in
    return float4(signal.Load(int3(px, 0)).rgb, 1);
}
