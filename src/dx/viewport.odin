package dx

import "base:runtime"
import "core:log"
import "vendor:directx/dxgi"

Viewport_Options :: struct {
    init_width: u32,
    init_height: u32,

    format: dxgi.FORMAT,
    depth_format: dxgi.FORMAT,
    clear_color: [4]f32,   // what the target clears to — also its optimized clear value, so the two can't drift

    ui_heap_srv: ^Descriptor_Heap,
}

Viewport :: struct {
    width: u32,
    height: u32,

    tex: Resource,
    heap_rtv: Descriptor_Heap,
    rtv: Resource_View,
    srv: Resource_View,

    depth_tex: Resource,
    heap_dsv: Descriptor_Heap,
    dsv: Resource_View,

    allocator: runtime.Allocator,

    using options: Viewport_Options
}

viewport_create :: proc(render_context: Render_Context, options: Viewport_Options, allocator := context.allocator) -> Viewport {
    if(options.ui_heap_srv.handle == nil) {
        log.error("Failed to create viewport because ui srv heap is nil")
        return Viewport{}
    }

    viewport: Viewport
    viewport.options = options
    viewport.width = options.init_width
    viewport.height = options.init_height
    viewport.allocator = allocator

    viewport.heap_rtv = descriptor_heap_create(render_context, {type = .RTV, cap = 1}, allocator)
    viewport.heap_dsv = descriptor_heap_create(render_context, {type = .DSV, cap = 1}, allocator)
    viewport_targets_create(render_context, &viewport)
    viewport.srv = descriptor_heap_register_srv(render_context, options.ui_heap_srv, viewport.tex)

    return viewport
}

viewport_destroy :: proc(viewport: Viewport) {
    descriptor_heap_destroy(viewport.heap_dsv)
    descriptor_heap_destroy(viewport.heap_rtv)
    texture2d_destroy(viewport.depth_tex)
    texture2d_destroy(viewport.tex)
    descriptor_heap_free(viewport.ui_heap_srv, viewport.srv.heap_slot)
}

viewport_resize :: proc(render_context: Render_Context, viewport: ^Viewport, width: u32, height: u32) {
    descriptor_heap_reset(&viewport.heap_dsv)
    descriptor_heap_reset(&viewport.heap_rtv)
    texture2d_destroy(viewport.depth_tex)
    texture2d_destroy(viewport.tex)

    viewport.width = width
    viewport.height = height

    viewport_targets_create(render_context, viewport)

    descriptor_heap_free(viewport.ui_heap_srv, viewport.srv.heap_slot)
    viewport.srv = descriptor_heap_register_srv(render_context, viewport.ui_heap_srv, viewport.tex)
}

viewport_targets_create :: proc(render_context: Render_Context, viewport: ^Viewport) {
    viewport.tex = texture2d_create(render_context, {format = viewport.format,
        width = viewport.width, height = viewport.height, mip_levels = 1, heap_type = .DEFAULT,
        flags = {.ALLOW_RENDER_TARGET}, clear_value = &{Format = viewport.format, Color = viewport.clear_color}})

    viewport.depth_tex = texture2d_create(render_context,{format = viewport.depth_format,
        width = viewport.width, height = viewport.height, mip_levels = 1, heap_type = .DEFAULT,
        flags = {.ALLOW_DEPTH_STENCIL}, clear_value = &{Format = viewport.depth_format, DepthStencil = {Depth = 0.0}}})

    viewport.rtv = descriptor_heap_register_rtv(render_context, &viewport.heap_rtv, viewport.tex)
    viewport.dsv = descriptor_heap_register_dsv(render_context, &viewport.heap_dsv, viewport.depth_tex)
}