package dx

import "base:runtime"
import "core:log"
import "vendor:directx/dxgi"

Viewport_Options :: struct {
    init_width: u32,
    init_height: u32,

    format: dxgi.FORMAT,       // the display target ImGui samples (post chain output)
    hdr_format: dxgi.FORMAT,   // the scene target the scene renders into (post chain input)
    depth_format: dxgi.FORMAT,
    clear_color: [4]f32,   // what the scene target clears to — also its optimized clear value, so the two can't drift

    ui_heap_srv: ^Descriptor_Heap,         // the display target's SRV, for ImGui
    resource_heap_srv: ^Descriptor_Heap,   // the scene target's SRV, for the post chain (bindless)
}

Viewport :: struct {
    width: u32,
    height: u32,

    tex: Resource,
    heap_rtv: Descriptor_Heap,   // [0] tex, [1] hdr_tex
    rtv: Resource_View,
    srv: Resource_View,

    hdr_tex: Resource,
    hdr_rtv: Resource_View,
    hdr_srv: Resource_View,

    depth_tex: Resource,
    heap_dsv: Descriptor_Heap,
    dsv: Resource_View,

    allocator: runtime.Allocator,

    using options: Viewport_Options
}

viewport_create :: proc(render_context: Render_Context, options: Viewport_Options, allocator := context.allocator) -> Viewport {
    if(options.ui_heap_srv.handle == nil || options.resource_heap_srv.handle == nil) {
        log.error("Failed to create viewport because a srv heap is nil")
        return Viewport{}
    }

    viewport: Viewport
    viewport.options = options
    viewport.width = options.init_width
    viewport.height = options.init_height
    viewport.allocator = allocator

    viewport.heap_rtv = descriptor_heap_create(render_context, {type = .RTV, cap = 2}, allocator)
    viewport.heap_dsv = descriptor_heap_create(render_context, {type = .DSV, cap = 1}, allocator)
    viewport_targets_create(render_context, &viewport)

    return viewport
}

viewport_destroy :: proc(viewport: Viewport) {
    viewport_targets_destroy(viewport)
    descriptor_heap_destroy(viewport.heap_dsv)
    descriptor_heap_destroy(viewport.heap_rtv)
}

viewport_resize :: proc(render_context: Render_Context, viewport: ^Viewport, width: u32, height: u32) {
    viewport_targets_destroy(viewport^)
    descriptor_heap_reset(&viewport.heap_dsv)
    descriptor_heap_reset(&viewport.heap_rtv)

    viewport.width = width
    viewport.height = height

    viewport_targets_create(render_context, viewport)
}

viewport_targets_create :: proc(render_context: Render_Context, viewport: ^Viewport) {
    // The display target is fully overwritten by the post chain each frame, so it has no clear value.
    viewport.tex = texture2d_create(render_context, {format = viewport.format,
        width = viewport.width, height = viewport.height, mip_levels = 1, heap_type = .DEFAULT,
        flags = {.ALLOW_RENDER_TARGET}})

    viewport.hdr_tex = texture2d_create(render_context, {format = viewport.hdr_format,
        width = viewport.width, height = viewport.height, mip_levels = 1, heap_type = .DEFAULT,
        flags = {.ALLOW_RENDER_TARGET}, clear_value = &{Format = viewport.hdr_format, Color = viewport.clear_color}})

    viewport.depth_tex = texture2d_create(render_context,{format = viewport.depth_format,
        width = viewport.width, height = viewport.height, mip_levels = 1, heap_type = .DEFAULT,
        flags = {.ALLOW_DEPTH_STENCIL}, clear_value = &{Format = viewport.depth_format, DepthStencil = {Depth = 0.0}}})

    viewport.rtv     = descriptor_heap_register_rtv(render_context, &viewport.heap_rtv, viewport.tex)
    viewport.hdr_rtv = descriptor_heap_register_rtv(render_context, &viewport.heap_rtv, viewport.hdr_tex)
    viewport.dsv     = descriptor_heap_register_dsv(render_context, &viewport.heap_dsv, viewport.depth_tex)
    viewport.srv     = descriptor_heap_register_srv(render_context, viewport.ui_heap_srv, viewport.tex)
    viewport.hdr_srv = descriptor_heap_register_srv(render_context, viewport.resource_heap_srv, viewport.hdr_tex)
}

@(private="file")
viewport_targets_destroy :: proc(viewport: Viewport) {
    descriptor_heap_free(viewport.ui_heap_srv, viewport.srv.heap_slot)
    descriptor_heap_free(viewport.resource_heap_srv, viewport.hdr_srv.heap_slot)
    texture2d_destroy(viewport.depth_tex)
    texture2d_destroy(viewport.hdr_tex)
    texture2d_destroy(viewport.tex)
}
