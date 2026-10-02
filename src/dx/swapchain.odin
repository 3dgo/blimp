package dx

import "base:runtime"
import "core:sys/windows"
import "vendor:directx/d3d12"
import "vendor:directx/dxgi"

Swapchain_Options :: struct {
    width: u32,
    height: u32,
    format: dxgi.FORMAT,
    depth_format: dxgi.FORMAT,
    num_frames: u32,
}

Swapchain :: struct {
    handle: ^dxgi.ISwapChain4,
    back_buffers: []Resource,
    back_buffer_views: []Resource_View,
    heap_rtv: Descriptor_Heap,
    depth_buffer: Resource,
    depth_view: Resource_View,
    heap_dsv: Descriptor_Heap,
    frame_idx: u32,

    allocator: runtime.Allocator,

    using options: Swapchain_Options,
}

swapchain_create :: proc(render_context: Render_Context, window: windows.HWND, queue: Command_Queue, options: Swapchain_Options, allocator := context.allocator) -> Swapchain {
    swapchain: Swapchain
    swapchain.options = options
    swapchain.allocator = allocator

    sc1: ^dxgi.ISwapChain1
    hr := render_context.factory->CreateSwapChainForHwnd(
        queue.handle,
        window,
        &dxgi.SWAP_CHAIN_DESC1 {
            Width = options.width,
            Height = options.height,
            Format = options.format,
            BufferUsage = {.RENDER_TARGET_OUTPUT},
            BufferCount = options.num_frames,
            SampleDesc = { Count = 1 },
            SwapEffect = .FLIP_DISCARD,
            Flags = {.ALLOW_TEARING},
        },
        nil,
        nil,
        &sc1,
    ); check_dx(hr, "Failed to create swapchain")

    sc1->QueryInterface(dxgi.ISwapChain4_UUID, (^rawptr)(&swapchain.handle))
    sc1->Release()

    render_context.factory->MakeWindowAssociation(window, {.NO_ALT_ENTER})

    swapchain.heap_rtv = descriptor_heap_create(render_context, {type = .RTV, cap = swapchain.num_frames}, allocator)

    swapchain_backbuffers_create_rtvs(render_context, &swapchain)
    swapchain_depth_create(render_context, &swapchain)

    return swapchain
}

swapchain_destroy :: proc(swapchain: ^Swapchain) {
    swapchain_depth_destroy(swapchain)
    swapchain_backbuffers_destroy(swapchain)
    descriptor_heap_destroy(swapchain.heap_rtv)

    swapchain.handle->Release()
}

swapchain_get_backbuffers :: proc(render_context: Render_Context, swapchain: ^Swapchain) {
    assert(swapchain.back_buffers == nil)
    swapchain.back_buffers = make([]Resource, swapchain.num_frames, swapchain.allocator)
    buffers := make([]^d3d12.IResource, swapchain.num_frames, context.temp_allocator)
    for i in 0..<swapchain.num_frames {
        hr := swapchain.handle->GetBuffer(u32(i), d3d12.IResource_UUID, (^rawptr)(&buffers[i])); check_dx(hr, "Failed to get swapchain back buffer")
        swapchain.back_buffers[i].handle = buffers[i]
        swapchain.back_buffers[i].options = Texture2D_Options {format = swapchain.format, width = swapchain.width, height = swapchain.height, mip_levels = 1, flags = {.ALLOW_RENDER_TARGET}}
        swapchain.back_buffers[i].current_access_flags = {.NO_ACCESS}
    }
}

swapchain_backbuffers_destroy :: proc(swapchain: ^Swapchain) {
    if swapchain.back_buffer_views != nil {
        delete(swapchain.back_buffer_views, swapchain.allocator)
        swapchain.back_buffer_views = nil
    }
    if swapchain.back_buffers != nil {
        for back_buffer in swapchain.back_buffers {
            buffer_destroy(back_buffer)
        }
        delete(swapchain.back_buffers, swapchain.allocator)
        swapchain.back_buffers = nil
    }
}

swapchain_backbuffers_create_rtvs :: proc(render_context: Render_Context, swapchain: ^Swapchain) {
    assert(swapchain.back_buffer_views == nil)
    descriptor_heap_reset(&swapchain.heap_rtv)
    swapchain_get_backbuffers(render_context, swapchain)
    swapchain.back_buffer_views = make([]Resource_View, swapchain.num_frames, swapchain.allocator)
    for bbuffer, i in swapchain.back_buffers {
        swapchain.back_buffer_views[i] = descriptor_heap_register_rtv(render_context, &swapchain.heap_rtv, bbuffer)
    }
}

swapchain_resize :: proc(render_context: Render_Context, swapchain: ^Swapchain, width, height: u32) {
    swapchain_depth_destroy(swapchain)
    swapchain_backbuffers_destroy(swapchain)
    swapchain.width = width
    swapchain.height = height
    hr := swapchain.handle->ResizeBuffers(swapchain.num_frames, width, height, .UNKNOWN, {.ALLOW_TEARING}); check_dx(hr, "Failed to resize swapchain.")
    swapchain_backbuffers_create_rtvs(render_context, swapchain)
    swapchain_depth_create(render_context, swapchain)
    swapchain.frame_idx = 0
}

swapchain_depth_create :: proc(render_context: Render_Context, swapchain: ^Swapchain) {
    depth_clear := d3d12.CLEAR_VALUE {
        Format = swapchain.depth_format,
        DepthStencil = {Depth = 1.0, Stencil = 0},
    }
    swapchain.depth_buffer = texture2d_create(render_context, {
        format     = swapchain.depth_format,
        width      = swapchain.width,
        height     = swapchain.height,
        mip_levels = 1,
        heap_type  = .DEFAULT,
        flags      = {.ALLOW_DEPTH_STENCIL},
        clear_value = &depth_clear,
    })
    swapchain.heap_dsv = descriptor_heap_create(render_context, {type = .DSV, cap = 1}, swapchain.allocator)
    swapchain.depth_view = descriptor_heap_register_dsv(render_context, &swapchain.heap_dsv, swapchain.depth_buffer)
}

swapchain_depth_destroy :: proc(swapchain: ^Swapchain) {
    descriptor_heap_destroy(swapchain.heap_dsv)
    texture2d_destroy(swapchain.depth_buffer)
}

swapchain_present :: proc(swapchain: ^Swapchain) {
    swapchain.handle->Present(0, {.ALLOW_TEARING})
    swapchain.frame_idx = swapchain.handle->GetCurrentBackBufferIndex()
}