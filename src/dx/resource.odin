package dx

import "vendor:directx/d3d12"
import "vendor:directx/dxgi"
import win32 "core:sys/windows"

Resource :: struct {
    handle: ^d3d12.IResource,
    options: Resource_Options,

    current_sync_flags: d3d12.BARRIER_SYNC_FLAGS,
    current_access_flags: d3d12.BARRIER_ACCESS_FLAGS,
    current_layout: d3d12.BARRIER_LAYOUT,
}

Resource_Options :: union {
    Buffer_Options,
    Texture2D_Options,
}

Buffer_Options :: struct {
    num_elements: u32,
    element_size: u32,
    heap_type: d3d12.HEAP_TYPE,
    flags: d3d12.RESOURCE_FLAGS,
}

Texture2D_Options :: struct {
    width: u32,
    height: u32,
    format: dxgi.FORMAT,
    mip_levels: u32,
    heap_type: d3d12.HEAP_TYPE,
    flags: d3d12.RESOURCE_FLAGS,
    clear_value: ^d3d12.CLEAR_VALUE,
    array_size: u32,   // slices; 0 or 1 = a plain 2D texture, more = a 2D array (SRV and DSVs become array views)
}

Resource_View :: struct {
    heap_slot: u32,
    cpu_handle: d3d12.CPU_DESCRIPTOR_HANDLE,
}

buffer_create :: proc(render_context: Render_Context, options: Buffer_Options) -> Resource {
    resource: Resource
    resource.options = options

    // Waiting for Odin DX update, Use newer Idevice so I can use CreateCommittedResource3 to work with ehanced barrier
    hr := render_context.device->CreateCommittedResource(
        &d3d12.HEAP_PROPERTIES { Type = options.heap_type },
        {},
        &d3d12.RESOURCE_DESC {
            Dimension = .BUFFER,
            Width = u64(options.num_elements) * u64(options.element_size),
            Height = 1,
            DepthOrArraySize = 1,
            MipLevels = 1,
            Format = .UNKNOWN,
            SampleDesc = { Count = 1 },
            Layout = .ROW_MAJOR,
            Flags = options.flags,
        },
        {},
        nil,
        d3d12.IResource_UUID,
        (^rawptr)(&resource.handle),
    ); check_dx(hr, "Failed to create buffer resource")
    resource.current_access_flags = {.NO_ACCESS}
    return resource
}

buffer_destroy :: proc(buffer: Resource) {
    buffer.handle->Release()
}

buffer_map :: proc(buffer: Resource) -> rawptr {
    map_ptr: rawptr
    hr := buffer.handle->Map(0, nil, &map_ptr); check_dx(hr, "Failed to map buffer.")
    return map_ptr
}

buffer_unmap :: proc(buffer: Resource) {
    buffer.handle->Unmap(0, nil)
}

texture2d_create :: proc(render_context: Render_Context, options: Texture2D_Options) -> Resource {
    resource: Resource
    resource.options = options

    hr := render_context.device->CreateCommittedResource(
        &d3d12.HEAP_PROPERTIES { Type = options.heap_type },
        {},
        &d3d12.RESOURCE_DESC {
            Dimension = .TEXTURE2D,
            Width = u64(options.width),
            Height = options.height,
            DepthOrArraySize = u16(max(options.array_size, 1)),
            MipLevels = u16(options.mip_levels),
            Format = options.format,
            SampleDesc = { Count = 1 },
            Layout = .UNKNOWN,
            Flags = options.flags,
        },
        {},
        options.clear_value,
        d3d12.IResource_UUID,
        (^rawptr)(&resource.handle),
    ); check_dx(hr, "Failed to create texture2d resource")
    resource.current_access_flags = {.NO_ACCESS}
    resource.current_layout = .UNDEFINED
    return resource
}

texture2d_destroy :: proc(texture2d: Resource) {
    texture2d.handle->Release()
}

buffer_transition :: proc(cmd: Command_List, buffer: ^Resource, new_sync_flags: d3d12.BARRIER_SYNC_FLAGS, new_access_flags: d3d12.BARRIER_ACCESS_FLAGS) {
    barrier := d3d12.BUFFER_BARRIER {
        SyncBefore = buffer.current_sync_flags,
        SyncAfter = new_sync_flags,
        AccessBefore = buffer.current_access_flags,
        AccessAfter = new_access_flags,
        pRessource = buffer.handle,
        Offset = 0,
        Size = max(u64),
    }
    barrier_grp := d3d12.BARRIER_GROUP {
        Type = .BUFFER,
        NumBarriers = 1,
        pBufferBarriers = &barrier
    }
    cmd.handle->Barrier(1, &barrier_grp)
    buffer.current_sync_flags = new_sync_flags
    buffer.current_access_flags = new_access_flags
}

texture_transition :: proc(cmd: Command_List, texture: ^Resource, new_sync_flags: d3d12.BARRIER_SYNC_FLAGS, new_access_flags: d3d12.BARRIER_ACCESS_FLAGS, new_layout: d3d12.BARRIER_LAYOUT) {
    barrier := d3d12.TEXTURE_BARRIER {
        SyncBefore = texture.current_sync_flags,
        SyncAfter = new_sync_flags,
        AccessBefore = texture.current_access_flags,
        AccessAfter = new_access_flags,
        LayoutBefore = texture.current_layout,
        LayoutAfter = new_layout,
        pResource = texture.handle,
        Subresources = {
            IndexOrFirstMipLevel = max(u32)
        }
    }
    barrier_grp := d3d12.BARRIER_GROUP {
        Type = .TEXTURE,
        NumBarriers = 1,
        pTextureBarriers = &barrier
    }
    cmd.handle->Barrier(1, &barrier_grp)
    texture.current_sync_flags = new_sync_flags
    texture.current_access_flags = new_access_flags
    texture.current_layout = new_layout
}

resource_get_gpu_address :: proc(resource: Resource) -> d3d12.GPU_VIRTUAL_ADDRESS {
    return resource.handle->GetGPUVirtualAddress()
}

// Named in release builds too: it's once per resource, and a capture of the shipped game reads the same.
resource_set_debug_name :: proc(resource: Resource, name: string) {
    wide := win32.utf8_to_wstring(name, context.temp_allocator)
    resource.handle->SetName(wide)
}