package dx

import "base:runtime"
import "core:log"
import "vendor:directx/dxgi"

// A view's targets: the scene renders into `hdr_tex` + `depth_tex` at the scene size, the post chain
// resolves that into `tex` at the display size, which ImGui samples. The scene size is the display
// size divided by `scene_scale`, rounded up — the low-res look upscales by a whole number.
// A retro view also has a scene-size intermediate for its post chain (post_targets).
Viewport_Options :: struct {
    init_width: u32,
    init_height: u32,
    scene_scale: u32,   // display pixels per scene pixel, each way; 0 counts as 1 (scene and display the same size)

    format: dxgi.FORMAT,       // the display target ImGui samples (post chain output)
    hdr_format: dxgi.FORMAT,   // the scene target the scene renders into (post chain input)
    depth_format: dxgi.FORMAT, // D32_FLOAT only: the depth buffer is also read as R32_FLOAT (depth_srv)
    clear_color: [4]f32,   // what the scene target clears to — also its optimized clear value, so the two can't drift
    post_targets: bool,    // the retro post chain's scene-size intermediate (signal_tex); a clean view has none

    ui_heap_srv: ^Descriptor_Heap,         // the display target's SRV, for ImGui
    resource_heap_srv: ^Descriptor_Heap,   // the scene target's and depth's SRVs, for the post chain (bindless)
}

Viewport :: struct {
    width: u32,          // the display target
    height: u32,
    scene_width: u32,    // the scene target and depth: ceil(display / scene_scale)
    scene_height: u32,

    tex: Resource,
    heap_rtv: Descriptor_Heap,   // [0] tex, [1] hdr_tex, then signal_tex
    rtv: Resource_View,
    srv: Resource_View,

    hdr_tex: Resource,
    hdr_rtv: Resource_View,
    hdr_srv: Resource_View,

    depth_tex: Resource,   // R32_TYPELESS, viewed as D32_FLOAT (dsv) and R32_FLOAT (depth_srv)
    heap_dsv: Descriptor_Heap,
    dsv: Resource_View,
    depth_srv: Resource_View,   // for passes at the display size, which can't bind the scene-sized depth as a DSV

    // The retro post chain's intermediate at the scene size (post_targets): the signal (display-space, the
    // display format).
    signal_tex: Resource,
    signal_rtv: Resource_View,
    signal_srv: Resource_View,

    allocator: runtime.Allocator,

    using options: Viewport_Options
}

viewport_create :: proc(render_context: Render_Context, options: Viewport_Options, allocator := context.allocator) -> Viewport {
    if(options.ui_heap_srv.handle == nil || options.resource_heap_srv.handle == nil) {
        log.error("Failed to create viewport because a srv heap is nil")
        return Viewport{}
    }
    if options.depth_format != .D32_FLOAT {
        log.errorf("Failed to create viewport: depth_format %v isn't D32_FLOAT", options.depth_format)
        return Viewport{}
    }

    viewport: Viewport
    viewport.options = options
    viewport.width = options.init_width
    viewport.height = options.init_height
    viewport.allocator = allocator

    viewport.heap_rtv = descriptor_heap_create(render_context, {type = .RTV, cap = 3}, allocator)
    viewport.heap_dsv = descriptor_heap_create(render_context, {type = .DSV, cap = 1}, allocator)
    viewport_targets_create(render_context, &viewport)

    return viewport
}

viewport_destroy :: proc(viewport: Viewport) {
    viewport_targets_destroy(viewport)
    descriptor_heap_destroy(viewport.heap_dsv)
    descriptor_heap_destroy(viewport.heap_rtv)
}

// Recreates the targets at a new display size and scene scale. The GPU must be done with the old ones.
viewport_resize :: proc(render_context: Render_Context, viewport: ^Viewport, width: u32, height: u32, scene_scale: u32, post_targets: bool) {
    viewport_targets_destroy(viewport^)
    descriptor_heap_reset(&viewport.heap_dsv)
    descriptor_heap_reset(&viewport.heap_rtv)

    viewport.width = width
    viewport.height = height
    viewport.scene_scale = scene_scale
    viewport.post_targets = post_targets

    viewport_targets_create(render_context, viewport)
}

@(private="file")
viewport_targets_create :: proc(render_context: Render_Context, viewport: ^Viewport) {
    scale := max(viewport.scene_scale, 1)
    viewport.scene_width  = (viewport.width  + scale - 1) / scale
    viewport.scene_height = (viewport.height + scale - 1) / scale

    // The display target is fully overwritten by the post chain each frame, so it has no clear value.
    viewport.tex = texture2d_create(render_context, {format = viewport.format,
        width = viewport.width, height = viewport.height, mip_levels = 1, heap_type = .DEFAULT,
        flags = {.ALLOW_RENDER_TARGET}})

    viewport.hdr_tex = texture2d_create(render_context, {format = viewport.hdr_format,
        width = viewport.scene_width, height = viewport.scene_height, mip_levels = 1, heap_type = .DEFAULT,
        flags = {.ALLOW_RENDER_TARGET}, clear_value = &{Format = viewport.hdr_format, Color = viewport.clear_color}})

    viewport.depth_tex = texture2d_create(render_context,{format = .R32_TYPELESS,
        width = viewport.scene_width, height = viewport.scene_height, mip_levels = 1, heap_type = .DEFAULT,
        flags = {.ALLOW_DEPTH_STENCIL}, clear_value = &{Format = viewport.depth_format, DepthStencil = {Depth = 0.0}}})

    viewport.rtv       = descriptor_heap_register_rtv(render_context, &viewport.heap_rtv, viewport.tex)
    viewport.hdr_rtv   = descriptor_heap_register_rtv(render_context, &viewport.heap_rtv, viewport.hdr_tex)
    viewport.dsv       = descriptor_heap_register_dsv(render_context, &viewport.heap_dsv, viewport.depth_tex, viewport.depth_format)
    viewport.srv       = descriptor_heap_register_srv(render_context, viewport.ui_heap_srv, viewport.tex)
    viewport.hdr_srv   = descriptor_heap_register_srv(render_context, viewport.resource_heap_srv, viewport.hdr_tex)
    viewport.depth_srv = descriptor_heap_register_srv(render_context, viewport.resource_heap_srv, viewport.depth_tex, .R32_FLOAT)

    if !viewport.post_targets do return
    viewport.signal_tex = texture2d_create(render_context, {format = viewport.format,
        width = viewport.scene_width, height = viewport.scene_height, mip_levels = 1, heap_type = .DEFAULT,
        flags = {.ALLOW_RENDER_TARGET}})
    viewport.signal_rtv = descriptor_heap_register_rtv(render_context, &viewport.heap_rtv, viewport.signal_tex)
    viewport.signal_srv = descriptor_heap_register_srv(render_context, viewport.resource_heap_srv, viewport.signal_tex)
}

@(private="file")
viewport_targets_destroy :: proc(viewport: Viewport) {
    if viewport.post_targets {
        descriptor_heap_free(viewport.resource_heap_srv, viewport.signal_srv.heap_slot)
        texture2d_destroy(viewport.signal_tex)
    }
    descriptor_heap_free(viewport.ui_heap_srv, viewport.srv.heap_slot)
    descriptor_heap_free(viewport.resource_heap_srv, viewport.hdr_srv.heap_slot)
    descriptor_heap_free(viewport.resource_heap_srv, viewport.depth_srv.heap_slot)
    texture2d_destroy(viewport.depth_tex)
    texture2d_destroy(viewport.hdr_tex)
    texture2d_destroy(viewport.tex)
}
