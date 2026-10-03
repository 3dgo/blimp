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
