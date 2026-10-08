module utils;

// Bindless access: a descriptor heap slot (a Frame_Constants *Slot field, or a material's texture) as the
// resource it holds.

public func getTexture2dRGBA(idx: uint) -> Texture2D<float4> {
    return DescriptorHandle<Texture2D<float4>>(idx);
}

public func getTexture2dF1(idx: uint) -> Texture2D<float> {
    return DescriptorHandle<Texture2D<float>>(idx);
}

public func getSampler(idx: uint) -> SamplerState {
    return DescriptorHandle<SamplerState>(idx);
}

// One skinned vertex's matrix (claude/rendering.md → Skinning): its four joints' skin matrices from the world's
// bone buffer, by its weights. A SkinVertex (Skin_Vertex) is two uints: four joint bytes, then four unorm8 weights.
public func skinMatrix(skinSlot: uint, boneSlot: uint, skinIndex: uint, boneOffset: uint) -> float4x4 {
    StructuredBuffer<uint2>    skins = DescriptorHandle<StructuredBuffer<uint2>>(skinSlot);
    StructuredBuffer<float4x4> bones = DescriptorHandle<StructuredBuffer<float4x4>>(boneSlot);
    uint2 sv = skins[skinIndex];
    float4x4 m = 0;
    for (uint k = 0; k < 4; k++) {
        uint  joint  = (sv.x >> (8 * k)) & 0xFF;
        float weight = float((sv.y >> (8 * k)) & 0xFF) / 255.0;
        m += bones[boneOffset + joint] * weight;
    }
    return m;
}

// A fullscreen triangle's clip position for vertex 0..2 of a 3-vertex draw: (0,0) (2,0) (0,2) in uv, covering
// the viewport.
public float4 fullscreen_triangle(uint vertexID) {
    float2 uv = float2((vertexID << 1) & 2, vertexID & 2);
    return float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
}

// 4x4 Bayer thresholds, (n + 0.5) / 16: added before a floor, they spread each value over its two nearest
// levels in the right proportion. Also an ordered per-pixel offset for stepped loops (fog), so what's left of
// the stepping breaks up like the dither.
public static const float BAYER_4X4[16] = {
     0.5 / 16,  8.5 / 16,  2.5 / 16, 10.5 / 16,
    12.5 / 16,  4.5 / 16, 14.5 / 16,  6.5 / 16,
     3.5 / 16, 11.5 / 16,  1.5 / 16,  9.5 / 16,
    15.5 / 16,  7.5 / 16, 13.5 / 16,  5.5 / 16,
};

// Pixel px's Bayer threshold, in (0, 1).
public float bayer4(uint2 px) {
    return BAYER_4X4[(px.y & 3) * 4 + (px.x & 3)];
}

public float3 linear_to_srgb(float3 c) {
    return select(c <= 0.0031308, c * 12.92, 1.055 * pow(c, 1.0 / 2.4) - 0.055);
}

// Bilinear `t` at continuous texel position `p` (texel centres at whole + 0.5), clamped at the edges.
public float3 load_bilinear(Texture2D<float4> t, float2 p, int2 size) {
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

// Unit direction → [-1, 1]²: +Z in the middle, -Z at the corners. Same as octahedral_encode in world_probes.odin.
public float2 octahedral_encode(float3 d) {
    float2 p = d.xy / (abs(d.x) + abs(d.y) + abs(d.z));
    if (d.z < 0) p = (1 - abs(p.yx)) * float2(p.x >= 0 ? 1 : -1, p.y >= 0 ? 1 : -1);
    return p;
}
