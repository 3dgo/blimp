package dx

import "vendor:directx/d3d12"

// Copies an RGBA8 2D texture to CPU memory, tightly packed (width*4 bytes per row). Fully
// synchronous: records a one-off command list on `queue`, then blocks until the GPU finishes.
// Tool path (screenshots) only — never per frame. The texture must already have been written by
// the GPU (its tracked layout isn't UNDEFINED); it's left in the layout it was in.
texture_readback_rgba8 :: proc(render_context: Render_Context, queue: Command_Queue, tex: ^Resource, allocator := context.allocator) -> (pixels: []u8, width, height: u32, ok: bool) {
    cmd_alloc := command_allocator_create(render_context, {type = .DIRECT})
    defer command_allocator_destroy(cmd_alloc)
    cmd := command_list_create(render_context, cmd_alloc, {type = .DIRECT})
    defer command_list_destroy(cmd)

    rb := texture_readback_record(render_context, cmd, tex) or_return
    command_list_close(cmd)
    command_list_execute(queue, {cmd})

    fence := fence_create(render_context, 0)
    defer fence_destroy(fence)
    command_queue_signal(queue, fence, 1)
    fence_wait(fence, 1)

    pixels = texture_readback_pixels(rb, allocator)
    return pixels, rb.width, rb.height, true
}

// A texture copy recorded into a command list and read on the CPU once the GPU has run it. For a copy
// that must happen at one point in a frame (the swapchain image, after the UI draws and before present).
Texture_Readback :: struct {
    buffer:               ^d3d12.IResource,   // READBACK heap; released by texture_readback_pixels
    width, height, pitch: u32,
}

// Records a copy of RGBA8 `tex` into a new readback buffer on `cmd`, leaving `tex` in the layout it was
// in. ok=false if it isn't a 2D texture or hasn't been written yet.
texture_readback_record :: proc(render_context: Render_Context, cmd: Command_List, tex: ^Resource) -> (rb: Texture_Readback, ok: bool) {
    opts := tex.options.(Texture2D_Options) or_return
    if tex.current_layout == .UNDEFINED do return
    rb.width, rb.height = opts.width, opts.height
    rb.pitch = (rb.width * 4 + 255) &~ 255   // D3D12_TEXTURE_DATA_PITCH_ALIGNMENT
    rb.buffer = readback_buffer_create(render_context, u64(rb.pitch) * u64(rb.height))

    prev_sync, prev_access, prev_layout := tex.current_sync_flags, tex.current_access_flags, tex.current_layout
    texture_transition(cmd, tex, {.COPY}, {.COPY_SOURCE}, .COPY_SOURCE)
    dst := d3d12.TEXTURE_COPY_LOCATION{pResource = rb.buffer, Type = .PLACED_FOOTPRINT}
    dst.PlacedFootprint = {Footprint = {Format = opts.format, Width = rb.width, Height = rb.height, Depth = 1, RowPitch = rb.pitch}}
    src := d3d12.TEXTURE_COPY_LOCATION{pResource = tex.handle, Type = .SUBRESOURCE_INDEX}
    cmd.handle->CopyTextureRegion(&dst, 0, 0, 0, &src, nil)
    texture_transition(cmd, tex, prev_sync, prev_access, prev_layout)
    return rb, true
}

// The copied pixels, tightly packed (width*4 bytes per row), and releases the buffer. Only once the GPU
// has finished the command list the copy was recorded into.
texture_readback_pixels :: proc(rb: Texture_Readback, allocator := context.allocator) -> []u8 {
    defer rb.buffer->Release()
    size := u64(rb.pitch) * u64(rb.height)
    mapped: rawptr
    hr := rb.buffer->Map(0, &d3d12.RANGE{0, uint(size)}, &mapped); check_dx(hr, "Failed to map readback buffer")
    defer rb.buffer->Unmap(0, &d3d12.RANGE{})
    row := int(rb.width) * 4
    pixels := make([]u8, row * int(rb.height), allocator)
    src_bytes := ([^]u8)(mapped)
    for y in 0 ..< int(rb.height) do copy(pixels[y * row:][:row], src_bytes[y * int(rb.pitch):][:row])
    return pixels
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
