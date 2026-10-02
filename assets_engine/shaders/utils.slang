module utils;

public func getBuffer<T>(idx: uint) -> StructuredBuffer<T> {
    return DescriptorHandle<StructuredBuffer<T>>(idx);
}

public func getRWBuffer<T>(idx: uint) -> RWStructuredBuffer<T> {
    return DescriptorHandle<RWStructuredBuffer<T>>(idx);
}

public func getRawBuffer(idx: uint) -> ByteAddressBuffer {
    return DescriptorHandle<ByteAddressBuffer>(idx);
}

public func getTexture2dRGBA(idx: uint) -> Texture2D<float4> {
    return DescriptorHandle<Texture2D<float4>>(idx);
}

public func getTexture2dF1(idx: uint) -> Texture2D<float> {
    return DescriptorHandle<Texture2D<float>>(idx);
}

public func getSampler(idx: uint) -> SamplerState {
    return DescriptorHandle<SamplerState>(idx);
}

public func getCMPSampler(idx: uint) -> SamplerComparisonState {
    return DescriptorHandle<SamplerComparisonState>(idx);
}