package dx

import "base:runtime"
import "core:log"
import "vendor:directx/d3d12"
import "vendor:directx/dxgi"

Descriptor_Heap :: struct {
    handle: ^d3d12.IDescriptorHeap,

    cpu_base: d3d12.CPU_DESCRIPTOR_HANDLE,
    gpu_base: d3d12.GPU_DESCRIPTOR_HANDLE,
    stride: u32,

    free_slots: [dynamic]u32,
    allocator: runtime.Allocator,

    using options: Descriptor_Heap_Options,
}

Descriptor_Heap_Options :: struct {
    type: d3d12.DESCRIPTOR_HEAP_TYPE,
    cap: u32,
    flags: d3d12.DESCRIPTOR_HEAP_FLAGS,
}

descriptor_heap_create :: proc(render_context: Render_Context, options: Descriptor_Heap_Options, allocator := context.allocator) -> Descriptor_Heap {
    descriptor_heap: Descriptor_Heap
    descriptor_heap.options = options
    descriptor_heap.allocator = allocator
    hr := render_context.device->CreateDescriptorHeap(&d3d12.DESCRIPTOR_HEAP_DESC {
        Type = options.type,
        NumDescriptors = options.cap,
        Flags = options.flags,
    }, d3d12.IDescriptorHeap_UUID, (^rawptr)(&descriptor_heap.handle)); check_dx(hr, "Failed to create descriptor heap")

    descriptor_heap.handle->GetCPUDescriptorHandleForHeapStart(&descriptor_heap.cpu_base)
    if .SHADER_VISIBLE in options.flags && options.type != .RTV && options.type != .DSV {
        descriptor_heap.handle->GetGPUDescriptorHandleForHeapStart(&descriptor_heap.gpu_base)
    }
    descriptor_heap.stride = render_context.device->GetDescriptorHandleIncrementSize(options.type)
    descriptor_heap.free_slots = make([dynamic]u32, options.cap, options.cap, allocator)
    for i := int(options.cap) - 1; i >= 0; i -= 1 {
        descriptor_heap.free_slots[i] = u32(i)
    }
    return descriptor_heap
}

descriptor_heap_destroy :: proc(descriptor_heap: Descriptor_Heap) {
    delete(descriptor_heap.free_slots)
    descriptor_heap.handle->Release()
}

// `format` overrides a texture's view format: needed when the resource is typeless (depth read as R32_FLOAT).
descriptor_heap_register_srv :: proc(render_context: Render_Context, descriptor_heap: ^Descriptor_Heap, resource: Resource, format := dxgi.FORMAT.UNKNOWN) -> Resource_View {
    view: Resource_View

    srv_desc := d3d12.SHADER_RESOURCE_VIEW_DESC {
        Shader4ComponentMapping = d3d12.DEFAULT_SHADER_4_COMPONENT_MAPPING,
    }

    switch options in resource.options {
        case Buffer_Options: {
            srv_desc.Format = .UNKNOWN
            srv_desc.ViewDimension = .BUFFER
            srv_desc.Buffer = {
                FirstElement = 0,
                NumElements = options.num_elements,
                StructureByteStride = options.element_size,
                Flags = {},
            }
        }
        case Texture2D_Options: {
            srv_desc.Format = format != .UNKNOWN ? format : options.format
            if options.array_size > 1 {
                srv_desc.ViewDimension = .TEXTURE2DARRAY
                srv_desc.Texture2DArray = {MipLevels = options.mip_levels, ArraySize = options.array_size}
            } else {
                srv_desc.ViewDimension = .TEXTURE2D
                srv_desc.Texture2D = {
                    MostDetailedMip = 0,
                    MipLevels = options.mip_levels,
                }
            }
        }
    }

    idx := descriptor_heap_alloc(descriptor_heap)
    cpu := descriptor_heap_cpu_handle_at(descriptor_heap^, idx)
    render_context.device->CreateShaderResourceView(resource.handle, &srv_desc, cpu)

    view.heap_slot = idx
    view.cpu_handle = cpu
    return view
}

descriptor_heap_register_rtv :: proc(render_context: Render_Context, descriptor_heap: ^Descriptor_Heap, resource: Resource) -> Resource_View {
    view: Resource_View

    rtv_desc := d3d12.RENDER_TARGET_VIEW_DESC {}

    switch options in resource.options {
        case Texture2D_Options: {
            rtv_desc.Format = options.format
            rtv_desc.ViewDimension = .TEXTURE2D
            rtv_desc.Texture2D = {
                MipSlice = 0,
                PlaneSlice = 0,
            }
        }
        case Buffer_Options: {
            log.errorf("Can't create RTV from a buffer")
            return view
        }
    }

    idx := descriptor_heap_alloc(descriptor_heap)
    cpu := descriptor_heap_cpu_handle_at(descriptor_heap^, idx)
    render_context.device->CreateRenderTargetView(resource.handle, &rtv_desc, cpu)
    
    view.heap_slot = idx
    view.cpu_handle = cpu
    return view
}

// `format` overrides the texture's format, as for descriptor_heap_register_srv. On a texture array the
// view is the one slice `array_slice`.
descriptor_heap_register_dsv :: proc(render_context: Render_Context, descriptor_heap: ^Descriptor_Heap, resource: Resource, format := dxgi.FORMAT.UNKNOWN, array_slice: u32 = 0) -> Resource_View {
    view: Resource_View

    dsv_desc := d3d12.DEPTH_STENCIL_VIEW_DESC{}

    switch options in resource.options {
        case Texture2D_Options: {
            dsv_desc.Format = format != .UNKNOWN ? format : options.format
            if options.array_size > 1 {
                dsv_desc.ViewDimension = .TEXTURE2DARRAY
                dsv_desc.Texture2DArray = {MipSlice = 0, FirstArraySlice = array_slice, ArraySize = 1}
            } else {
                dsv_desc.ViewDimension = .TEXTURE2D
                dsv_desc.Texture2D = {MipSlice = 0}
            }
        }
        case Buffer_Options: {
            log.errorf("Can't create DSV from a buffer")
            return view
        }
    }

    idx := descriptor_heap_alloc(descriptor_heap)
    cpu := descriptor_heap_cpu_handle_at(descriptor_heap^, idx)
    render_context.device->CreateDepthStencilView(resource.handle, &dsv_desc, cpu)

    view.heap_slot = idx
    view.cpu_handle = cpu
    return view
}

descriptor_heap_register_sampler :: proc(render_context: Render_Context, descriptor_heap: ^Descriptor_Heap, desc: d3d12.SAMPLER_DESC) -> Resource_View {
    view: Resource_View
    idx := descriptor_heap_alloc(descriptor_heap)
    cpu := descriptor_heap_cpu_handle_at(descriptor_heap^, idx)
    d := desc
    render_context.device->CreateSampler(&d, cpu)
    view.heap_slot = idx
    view.cpu_handle = cpu
    return view
}

descriptor_heap_alloc :: proc(descriptor_heap: ^Descriptor_Heap) -> u32 {
    if len(descriptor_heap.free_slots) <= 0 {
        log.panicf("Descriptor heap is full, cannot allocate")
    }
    
    slot := pop(&descriptor_heap.free_slots)

    return slot
}

descriptor_heap_free :: proc(descriptor_heap: ^Descriptor_Heap, slot: u32) {
    append(&descriptor_heap.free_slots, slot)
}

descriptor_heap_cpu_handle_at :: proc(descriptor_heap: Descriptor_Heap, idx: u32) -> d3d12.CPU_DESCRIPTOR_HANDLE {
    return { ptr = descriptor_heap.cpu_base.ptr + uint(idx * descriptor_heap.stride) }
}

descriptor_heap_gpu_handle_at :: proc(descriptor_heap: Descriptor_Heap, idx: u32) -> d3d12.GPU_DESCRIPTOR_HANDLE {
    return { ptr = descriptor_heap.gpu_base.ptr + u64(idx * descriptor_heap.stride) }
}

descriptor_heap_bind :: proc(cmd: Command_List, descriptor_heaps: []Descriptor_Heap) {
    if len(descriptor_heaps) <= 0 do return

    heaps := make([]^d3d12.IDescriptorHeap, len(descriptor_heaps), context.temp_allocator)
    for heap, i in descriptor_heaps {
        heaps[i] = heap.handle
    }
    cmd.handle->SetDescriptorHeaps(u32(len(descriptor_heaps)), raw_data(heaps))
}

descriptor_heap_reset :: proc(descriptor_heaps: ^Descriptor_Heap) {
    clear(&descriptor_heaps.free_slots)
    resize(&descriptor_heaps.free_slots, descriptor_heaps.cap)
    for i := int(descriptor_heaps.cap) - 1; i >= 0; i -= 1 {
        descriptor_heaps.free_slots[i] = u32(i)
    }
}