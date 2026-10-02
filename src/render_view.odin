package blimp

import "core:math"
import "core:mem"
import "vendor:directx/d3d12"
import "vendor:directx/dxgi"
import "dx"

// A view onto a world: a render target, a camera, and the per-flight frame constants that pair
// the camera with the world's buffers. Many views can look at one world (each with its own
// camera) — the world owns the draw data they share, the view owns only what's per-camera.
Render_View :: struct {
    target: dx.Viewport,
    camera: Camera,
    world:  ^World,
    game_camera: Entity_Handle,   // set (game mode): renders through this camera entity of `world` instead of `camera`
    mode: Render_Mode,            // the PS1 look (default) or a clean full-res render; the editor toggles it per view
    // Lighting debug (the editor's toolbar lighting menu; a game view keeps the defaults). Like `mode`, these only
    // pick frame constants.
    lighting:       Lighting_View,
    probes_off:     bool,   // light as if not baked (the flat ambient), to compare
    indirect_scale: f32,    // × the indirect light (probes or the flat ambient): 1 = as baked

    frame_constants:    [FRAMES_IN_FLIGHT]dx.Resource,
    frame_constants_ptr: [FRAMES_IN_FLIGHT]rawptr,

    id:   u32,    // stable id: its ImGui window ("###view<id>" / "###host<id>") and blimpctl's <view>
    open: bool,   // its window's open flag — the user closing the window closes the view

    // Editor interaction (screen rect, navigation, gizmo, marquee) lives on the matching
    // Editor_View (editor_view.odin), not here.
    debug_first, debug_count: u32,   // this frame's overlay range in debug_draw.verts
}

// The scene target: linear, float, unclamped. Quantized only at the end of the post chain.
VIEW_HDR_FORMAT :: dxgi.FORMAT.R16G16B16A16_FLOAT

// How a view renders (docs/rendering.md, PS1 art direction). Both run the same shaders and passes; the
// mode only picks the frame constants (sampler, dither, snap, affine) and the target's scene scale.
//   PS1   — scene at ~PS1_LINES lines, upscaled by a whole number; vertices snapped to scene pixels;
//           affine UVs; point sampling; 5-bit dither
//   Clean — scene at the display size; none of the rest
Render_Mode :: enum u8 { PS1, Clean }

// Which lighting terms a view shows. Mirrors LIGHTING_* in common.slang.
//   Lit           — everything
//   Probes_Only   — the probes' light on white: what the bake gives, without textures or direct light
//   Indirect_Only — albedo × probes
//   Direct_Only   — albedo × realtime lights
//   Lighting_Only — direct + indirect on white
Lighting_View :: enum u32 { Lit, Probes_Only, Indirect_Only, Direct_Only, Lighting_Only }

PS1_LINES  :: 216   // 384×216 scales ×5 to 1080p exactly
PS1_AFFINE :: 1.0   // UV warp in .PS1: 1 = the full PS1 affine mapping, lower softens it on big polygons

// Display pixels per scene pixel for a view of display size `size`: the whole number that brings its
// height closest to PS1_LINES (never below 1), or 1 when the view renders clean.
render_view_scene_scale :: proc(view: ^Render_View, size: uvec2) -> u32 {
    if view.mode == .Clean do return 1
    return max(1, u32(math.round(f32(size.y) / PS1_LINES)))
}

render_view_create :: proc(view: ^Render_View, world: ^World, camera: Camera, width, height: u32) {
    view.world  = world
    view.camera = camera
    view.indirect_scale = 1
    view.target = dx.viewport_create(renderer_dx.render_context,
        {init_width = width, init_height = height, scene_scale = render_view_scene_scale(view, {width, height}),
         format = .R8G8B8A8_UNORM, hdr_format = VIEW_HDR_FORMAT, depth_format = .D32_FLOAT,
         clear_color = render_view_clear_color(world), ui_heap_srv = &renderer_dx.ui_heap, resource_heap_srv = &renderer_dx.resource_heap},
        app.allocators.perm)
    for i in 0..<FRAMES_IN_FLIGHT {
        view.frame_constants[i]     = dx.buffer_create(renderer_dx.render_context, {element_size = size_of(Frame_Constants), num_elements = 1, heap_type = .UPLOAD})
        view.frame_constants_ptr[i] = dx.buffer_map(view.frame_constants[i])
    }
}

render_view_destroy :: proc(view: ^Render_View) {
    for i in 0..<FRAMES_IN_FLIGHT {
        dx.buffer_unmap(view.frame_constants[i])
        dx.buffer_destroy(view.frame_constants[i])
    }
    dx.viewport_destroy(view.target)
}

render_view_resize :: proc(view: ^Render_View, width, height: u32) {
    dx.viewport_resize(renderer_dx.render_context, &view.target, width, height, render_view_scene_scale(view, {width, height}))
}

// The camera entity `view` renders through, if it has one that's still a camera in its world. When it
// doesn't (none set, or the game deleted it), the view renders through its editor camera.
render_view_game_camera :: proc(view: ^Render_View) -> (^Entity, bool) {
    if view.game_camera == {} do return nil, false
    e, ok := entity_get(view.world, view.game_camera)
    return e, ok && e.camera_type != .None
}

// ============================ Per-frame ============================
// A view's share of the frame. The world it looks at must already be staged and transitioned
// readable (world_render_upload / world_render_begin) — once per world, not once per view.

// Writes this view's frame constants for `frame_slot`: its camera, its world's per-flight buffer
// slots, and the shared asset buffer slots.
render_view_update_constants :: proc(view: ^Render_View, frame_slot: u64) {
    world  := view.world
    aspect := f32(view.target.width) / f32(view.target.height)
    scale  := max(view.target.scene_scale, 1)

    frame_constants := Frame_Constants{
        view_mat              = camera_view(view.camera),
        proj_mat              = camera_proj(view.camera, aspect),
        time                  = f32(timer_sec_since_start()),
        resolution            = {view.target.width, view.target.height},
        camera_pos            = camera_eye(view.camera),
        light_count           = u32(len(world.render.lights_data)),
        
        transform_buffer_slot     = world.render.transform[frame_slot].resource_view.heap_slot,
        mesh_instance_buffer_slot = world.render.mesh_instance[frame_slot].resource_view.heap_slot,
        lights_buffer_slot        = world.render.lights[frame_slot].resource_view.heap_slot,
        
        mesh_buffer_slot      = asset_buffers.mesh_buffer.resource_view.heap_slot,
        index_buffer_slot     = asset_buffers.index_buffer.resource_view.heap_slot,
        position_buffer_slot  = asset_buffers.position_buffer.resource_view.heap_slot,
        attribute_buffer_slot = asset_buffers.attribute_buffer.resource_view.heap_slot,
        material_buffer_slot  = asset_buffers.material_buffer.resource_view.heap_slot,
        sampler_slot          = view.mode == .PS1 ? asset_buffers.sampler_point.heap_slot : asset_buffers.sampler.heap_slot,
        
        debug_line_buffer_slot = debug_draw.buffer_srv[frame_slot].heap_slot,
        hdr_texture_slot       = view.target.hdr_srv.heap_slot,
        exposure               = math.pow(2, world.settings.exposure),
        depth_texture_slot     = view.target.depth_srv.heap_slot,
        scene_scale            = scale,
        dither                 = view.mode == .PS1 ? 1 : 0,
        scene_cover            = {f32(view.target.width)  / f32(scale * view.target.scene_width),
                                  f32(view.target.height) / f32(scale * view.target.scene_height)},
        vertex_snap            = view.mode == .PS1 ? {f32(view.target.scene_width) / 2, f32(view.target.scene_height) / 2} : {},
        affine                 = view.mode == .PS1 ? PS1_AFFINE : 0,

        shadow_map_slot         = world.render.shadow_map_srv.heap_slot,
        shadow_view_buffer_slot = world.render.shadow_views_srv[frame_slot].heap_slot,
    }
    // A play world lights with its level's probes (it has none of its own).
    frame_constants.lighting_view  = u32(view.lighting)
    frame_constants.indirect_scale = view.indirect_scale
    if level := world_level(world); level.render.probes.resource.handle != nil && !view.probes_off {
        g := &level.probes
        frame_constants.probe_buffer_slot = level.render.probes.resource_view.heap_slot
        frame_constants.probe_origin      = g.origin
        frame_constants.probe_spacing     = g.spacing
        frame_constants.probe_dims        = {u32(g.dims.x), u32(g.dims.y), u32(g.dims.z)}
        frame_constants.probe_layers      = u32(g.layers)
        scales := probe_layer_scales(g, light_group_scales(world, timer_sec_since_start()))   // this world's: a play world's power cut
        for s, k in scales do frame_constants.probe_layer_scale[k / 4][k % 4] = s
    }
    if e, ok := render_view_game_camera(view); ok {
        frame_constants.view_mat = entity_camera_view(e)
        frame_constants.proj_mat = entity_camera_proj(e, aspect)
        frame_constants.camera_pos = e.position
    }
    mem.copy(view.frame_constants_ptr[frame_slot], &frame_constants, size_of(Frame_Constants))
}

// Records the scene pass: clears the view's HDR scene target and draws its world's mesh instances into it.
// The post chain (render_post.odin) then resolves it into the display target.
render_view_draw :: proc(view: ^Render_View, frame_slot: u64) {
    cmd   := renderer_dx.cmd_gfx
    world := view.world

    dx.texture_transition(cmd, &view.target.hdr_tex, {.RENDER_TARGET}, {.RENDER_TARGET}, .RENDER_TARGET)
    dx.texture_transition(cmd, &view.target.depth_tex, {.DEPTH_STENCIL}, {.DEPTH_STENCIL_WRITE}, .DEPTH_STENCIL_WRITE)
    cmd.handle->OMSetRenderTargets(1, &view.target.hdr_rtv.cpu_handle, false, &view.target.dsv.cpu_handle)

    cmd.handle->ClearRenderTargetView(view.target.hdr_rtv.cpu_handle, &view.target.clear_color, 0, nil)
    cmd.handle->ClearDepthStencilView(view.target.dsv.cpu_handle, {.DEPTH}, 0.0, 0, 0, nil)   // reversed-Z: 0 = far

    dx.descriptor_heap_bind(cmd, {renderer_dx.resource_heap, renderer_dx.sampler_heap})
    cmd.handle->SetGraphicsRootSignature(renderer_dx.root_signature.handle)
    cmd.handle->SetPipelineState(renderer_dx.scene_pso.handle)

    // The scene target's size, low-res in .PS1: the post pass upscales it to the display.
    dx_viewport := d3d12.VIEWPORT{Width = f32(view.target.scene_width), Height = f32(view.target.scene_height), MaxDepth = 1.0}
    scissor     := d3d12.RECT{right = i32(view.target.scene_width), bottom = i32(view.target.scene_height)}
    cmd.handle->RSSetViewports(1, &dx_viewport)
    cmd.handle->RSSetScissorRects(1, &scissor)
    cmd.handle->IASetPrimitiveTopology(.TRIANGLELIST)

    cmd.handle->SetGraphicsRootConstantBufferView(0, dx.resource_get_gpu_address(view.frame_constants[frame_slot]))
    cmd.handle->IASetIndexBuffer(&d3d12.INDEX_BUFFER_VIEW{BufferLocation = dx.resource_get_gpu_address(asset_buffers.index_buffer.resource), SizeInBytes = u32(len(asset_system.vertex_indices) * size_of(u32)), Format = .R32_UINT})
    cmd.handle->ExecuteIndirect(renderer_dx.indirect_sig.handle, u32(len(world.render.draw_cmd_data)), world.render.draw_cmd[frame_slot].handle, 0, nil, 0)
}

// Target → shader resource, so the UI pass can sample it into an ImGui window.
render_view_end :: proc(view: ^Render_View) {
    dx.texture_transition(renderer_dx.cmd_gfx, &view.target.tex, {.PIXEL_SHADING}, {.SHADER_RESOURCE}, .SHADER_RESOURCE)
}

// The view's background: its world's settings.background, a display-space (sRGB) colour, cleared with
// alpha 0 so the post pass passes it through as picked (the scene writes alpha 1). It's also the target's
// optimized clear value, so when it changes the target is recreated (render_view_needs_rebuild) rather
// than cleared to a mismatched colour.
render_view_clear_color :: proc(w: ^World) -> [4]f32 {
    bg := w.settings.background
    return {bg.r, bg.g, bg.b, 0}
}

// True when the target must be recreated before drawing: a new size, a new scene scale (from the size or
// the render mode), or a new background colour. Recreating waits for the GPU, so the caller does it
// between frames (renderer_dx_resize_view).
render_view_needs_rebuild :: proc(view: ^Render_View, size: uvec2) -> bool {
    return size.x != view.target.width || size.y != view.target.height ||
        view.target.scene_scale != render_view_scene_scale(view, size) ||
        view.target.clear_color != render_view_clear_color(view.world)
}

