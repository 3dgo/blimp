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
