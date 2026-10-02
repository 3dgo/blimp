package dx

import "vendor:directx/d3d12"

// Copies an RGBA8 2D texture to CPU memory, tightly packed (width*4 bytes per row). Fully
// synchronous: records a one-off command list on `queue`, then blocks until the GPU finishes.
// Tool path (screenshots) only — never per frame. The texture must already have been written by
// the GPU (its tracked layout isn't UNDEFINED); it's left in the layout it was in.
texture_readback_rgba8 :: proc(render_context: Render_Context, queue: Command_Queue, tex: ^Resource, allocator := context.allocator) -> (pixels: []u8, width, height: u32, ok: bool) {
    opts := tex.options.(Texture2D_Options) or_return
    if tex.current_layout == .UNDEFINED do return
    width, height = opts.width, opts.height
    pitch := (width * 4 + 255) &~ 255   // D3D12_TEXTURE_DATA_PITCH_ALIGNMENT
    size := u64(pitch) * u64(height)

    readback := readback_buffer_create(render_context, size)
    defer readback->Release()

    cmd_alloc := command_allocator_create(render_context, {type = .DIRECT})
    defer command_allocator_destroy(cmd_alloc)
    cmd := command_list_create(render_context, cmd_alloc, {type = .DIRECT})
    defer command_list_destroy(cmd)

    prev_sync, prev_access, prev_layout := tex.current_sync_flags, tex.current_access_flags, tex.current_layout
    texture_transition(cmd, tex, {.COPY}, {.COPY_SOURCE}, .COPY_SOURCE)
    dst := d3d12.TEXTURE_COPY_LOCATION{pResource = readback, Type = .PLACED_FOOTPRINT}
    dst.PlacedFootprint = {Footprint = {Format = opts.format, Width = width, Height = height, Depth = 1, RowPitch = pitch}}
    src := d3d12.TEXTURE_COPY_LOCATION{pResource = tex.handle, Type = .SUBRESOURCE_INDEX}
    cmd.handle->CopyTextureRegion(&dst, 0, 0, 0, &src, nil)
    texture_transition(cmd, tex, prev_sync, prev_access, prev_layout)
    command_list_close(cmd)
    command_list_execute(queue, {cmd})

    fence := fence_create(render_context, 0)
    defer fence_destroy(fence)
    command_queue_signal(queue, fence, 1)
    fence_wait(fence, 1)

    mapped: rawptr
    hr := readback->Map(0, &d3d12.RANGE{0, uint(size)}, &mapped); check_dx(hr, "Failed to map readback buffer")
    defer readback->Unmap(0, &d3d12.RANGE{})
    row := int(width) * 4
    pixels = make([]u8, row * int(height), allocator)
    src_bytes := ([^]u8)(mapped)
    for y in 0 ..< int(height) do copy(pixels[y * row:][:row], src_bytes[y * int(pitch):][:row])
    return pixels, width, height, true
}

// A buffer the GPU copies into and the CPU maps to read (READBACK heap). Readback heaps must start
// in COPY_DEST under the legacy create call (buffer_create passes COMMON), hence its own proc.
readback_buffer_create :: proc(render_context: Render_Context, size: u64) -> ^d3d12.IResource {
    readback: ^d3d12.IResource
    hr := render_context.device->CreateCommittedResource(
        &d3d12.HEAP_PROPERTIES{Type = .READBACK}, {},
        &d3d12.RESOURCE_DESC{
            Dimension = .BUFFER, Width = size, Height = 1, DepthOrArraySize = 1, MipLevels = 1,
            Format = .UNKNOWN, SampleDesc = {Count = 1}, Layout = .ROW_MAJOR,
        },
        {.COPY_DEST}, nil, d3d12.IResource_UUID, (^rawptr)(&readback),
    ); check_dx(hr, "Failed to create readback buffer")
    return readback
}
