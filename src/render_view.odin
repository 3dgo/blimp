package blimp

import "core:math"
import "core:math/linalg"
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
    camera_entity: Entity_Handle,   // set (game mode): renders through this camera entity of `world` instead of `camera`
    mode: Render_Mode,            // the retro look (default) or a clean full-res render; the editor toggles it per view
    // Lighting debug (the editor's toolbar lighting menu; a game view keeps the defaults). Like `mode`, these only
    // pick frame constants.
    lighting:       Lighting_View,
    probes_off:     bool,   // light as if not baked (the flat ambient), to compare
    indirect_scale: f32,    // × the indirect light (probes or the flat ambient): 1 = as baked

    frame_constants:    [FRAMES_IN_FLIGHT]dx.Resource,
    frame_constants_ptr: [FRAMES_IN_FLIGHT]rawptr,

    id:   u32,    // stable id: its ImGui window ("###view<id>" / "###host<id>") and blimpctl's <view>

    // Editor interaction (screen rect, navigation, gizmo, marquee) lives on the matching
    // Editor_View (editor_view.odin), not here.
    debug_first, debug_count: u32,   // this frame's overlay range in debug_draw.verts
}

// The scene target: linear, float, unclamped. Quantized only at the end of the post chain.
VIEW_HDR_FORMAT :: dxgi.FORMAT.R16G16B16A16_FLOAT

// How a view renders (claude/rendering.md, Retro look). Both run the same scene shaders and passes; the
// mode picks the frame constants (sampler, snap, affine, quantize), the target's scene scale, and
// whether the post chain runs its retro passes (render_post.odin).
//   Retro — the PS1 effects of its level's Retro_Settings (each switchable, with its amounts)
//   Clean — scene at the display size; none of them
Render_Mode :: enum u8 { Retro, Clean }

// Which lighting terms a view shows. Mirrors LIGHTING_* in common.slang.
//   Lit           — everything
//   Probes_Only   — the probes' light on white: what the bake gives, without textures or direct light
//   Indirect_Only — albedo × probes
//   Direct_Only   — albedo × realtime lights
//   Lighting_Only — direct + indirect on white
Lighting_View :: enum u32 { Lit, Probes_Only, Indirect_Only, Direct_Only, Lighting_Only }

// The retro effects this view shows: its world's settings, like every other setting; all off in .Clean.
render_view_retro :: proc(view: ^Render_View) -> Retro_Settings {
    if view.mode == .Clean do return {}
    return view.world.settings.retro
}

// Display pixels per scene pixel for a view of display size `size`: with low resolution on, the whole
// number that brings its height closest to the retro `lines` (never below 1); else 1.
render_view_scene_scale :: proc(view: ^Render_View, size: uvec2) -> u32 {
    r := render_view_retro(view)
    if !r.low_res do return 1
    return max(1, u32(math.round(f32(size.y) / f32(max(r.lines, 1)))))
}

render_view_create :: proc(view: ^Render_View, world: ^World, camera: Camera, width, height: u32) {
    view.world  = world
    view.camera = camera
    view.indirect_scale = 1
    view.target = dx.viewport_create(renderer_dx.render_context,
        {init_width = width, init_height = height, scene_scale = render_view_scene_scale(view, {width, height}),
         post_targets = view.mode == .Retro,
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
    dx.viewport_resize(renderer_dx.render_context, &view.target, width, height, render_view_scene_scale(view, {width, height}), view.mode == .Retro)
}

// The camera entity `view` renders through, if it has one that can still be the game camera
// (entity_is_game_camera). When it doesn't (none set, or the game deleted or disabled it), the view
// renders through its free `camera`.
render_view_camera_entity :: proc(view: ^Render_View) -> (^Entity, bool) {
    if view.camera_entity == {} do return nil, false
    e, ok := entity_get(view.world, view.camera_entity)
    return e, ok && entity_is_game_camera(e)
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
    r := render_view_retro(view)
    bits := clamp(r.color_bits, RETRO_COLOR_BITS_MIN, 8)

    frame_constants := Frame_Constants{
        view_mat              = camera_view(view.camera),
        proj_mat              = camera_proj(view.camera, aspect),
        camera_pos            = camera_eye(view.camera),
        light_count           = u32(len(world.render.lights_data)),

        transform_buffer_slot     = world.render.transform[frame_slot].resource_view.heap_slot,
        mesh_instance_buffer_slot = world.render.mesh_instance[frame_slot].resource_view.heap_slot,
        lights_buffer_slot        = world.render.lights[frame_slot].resource_view.heap_slot,

        mesh_buffer_slot      = asset_buffers.mesh_buffer.resource_view.heap_slot,
        position_buffer_slot  = asset_buffers.position_buffer.resource_view.heap_slot,
        attribute_buffer_slot = asset_buffers.attribute_buffer.resource_view.heap_slot,
        skin_buffer_slot      = asset_buffers.skin_buffer.resource_view.heap_slot,
        bone_buffer_slot      = world.render.bones[frame_slot].resource_view.heap_slot,
        material_buffer_slot  = asset_buffers.material_buffer.resource_view.heap_slot,
        sampler_slot          = r.point_sampling ? asset_buffers.sampler_point.heap_slot : asset_buffers.sampler.heap_slot,

        debug_line_buffer_slot = debug_draw.buffer_srv[frame_slot].heap_slot,
        hdr_texture_slot       = view.target.hdr_srv.heap_slot,
        exposure               = math.pow(2, world.settings.exposure),
        depth_texture_slot     = view.target.depth_srv.heap_slot,
        scene_scale            = scale,
        color_levels           = r.quantize ? f32(u32(1) << u32(bits) - 1) : 0,
        scene_cover            = {f32(view.target.width)  / f32(scale * view.target.scene_width),
                                  f32(view.target.height) / f32(scale * view.target.scene_height)},
        scene_size             = {f32(view.target.scene_width), f32(view.target.scene_height)},
        vertex_snap            = r.vertex_snap ? {f32(view.target.scene_width), f32(view.target.scene_height)} / (2 * max(r.snap, 0.1)) : {},
        affine                 = r.affine ? clamp(r.warp, 0, 1) : 0,

        shadow_map_slot         = world.render.shadow_map_srv.heap_slot,
        shadow_view_buffer_slot = world.render.shadow_views_srv[frame_slot].heap_slot,

        signal_texture_slot    = view.target.signal_srv.heap_slot,
        dither                 = clamp(r.dither, 0, 1),
    }
    // A play world lights with its level's probes (it has none of its own).
    frame_constants.lighting_view  = u32(view.lighting)
    frame_constants.indirect_scale = view.indirect_scale
    if level := world_level(world); level.render.probes.resource.handle != nil && !view.probes_off {
        g := &level.probes
        frame_constants.probe_buffer_slot = level.render.probes.resource_view.heap_slot
        frame_constants.probe_depth_slot  = level.render.probe_depth.resource_view.heap_slot
        frame_constants.probe_origin      = g.origin
        frame_constants.probe_spacing     = g.spacing
        frame_constants.probe_dims        = {u32(g.dims.x), u32(g.dims.y), u32(g.dims.z)}
        frame_constants.probe_layers      = u32(g.layers)
        scales := probe_layer_scales(g, light_group_scales(world))   // this world's: a play world's power cut
        for s, k in scales do frame_constants.probe_layer_scale[k / 4][k % 4] = s
    }
    if e, ok := render_view_camera_entity(view); ok {
        frame_constants.view_mat = entity_camera_view(e)
        frame_constants.proj_mat = entity_camera_proj(e, aspect)
        frame_constants.camera_pos = e.position
    }
    frame_constants.inv_proj = linalg.inverse(frame_constants.proj_mat)
    render_view_fog(&frame_constants, world.settings.fog, world_level(world).probes.light_mean)
    render_view_sky(&frame_constants, world.settings.sky)
    mem.copy(view.frame_constants_ptr[frame_slot], &frame_constants, size_of(Frame_Constants))
}

// World_Settings.fog → the frame constants, each part left at 0 when it's off (post.slang skips it). Lit fog
// needs probes in the frame constants (fc.probe_dims) and their average light.
render_view_fog :: proc(fc: ^Frame_Constants, fog: Fog_Settings, light_mean: vec3) {
    fc.fog_color = fog.color
    if fog.distance_fog && fog.end > fog.start {
        fc.fog_start, fc.fog_end, fc.fog_max_opacity = fog.start, fog.end, clamp(fog.max_opacity, 0, 1)
    }
    if fog.height_fog && fog.density > 0 {
        fc.fog_height, fc.fog_density, fc.fog_falloff = fog.height, fog.density, max(fog.falloff, 0.01)
    }
    if fog.halos do fc.fog_glow = max(fog.glow, 0)
    if fc.probe_dims.x > 0 && light_mean != {} {
        fc.fog_lit, fc.fog_light_mean = clamp(fog.lit, 0, 1), light_mean
    }
}

// The sky's image: its texture setting, when that names a loaded image. A key nothing loaded under (a missing
// file) draws the background colour instead.
render_sky_image :: proc(sky: Sky_Settings) -> (image: u32, ok: bool) {
    if sky.texture == "" do return
    return asset_system.image_ids[sky.texture]
}

// World_Settings.sky → the frame constants, when there's a sky to draw.
render_view_sky :: proc(fc: ^Frame_Constants, sky: Sky_Settings) {
    image, ok := render_sky_image(sky)
    if !ok do return
    fc.sky_texture_slot = asset_buffers.texture_buffers[image].resource_view.heap_slot
    fc.sky_intensity    = max(sky.intensity, 0)
    fc.sky_rotation     = sky.rotation / 360
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

    // The scene target's size, low-res in .Retro: the post chain upscales it to the display.
    dx_viewport := d3d12.VIEWPORT{Width = f32(view.target.scene_width), Height = f32(view.target.scene_height), MaxDepth = 1.0}
    scissor     := d3d12.RECT{right = i32(view.target.scene_width), bottom = i32(view.target.scene_height)}
    cmd.handle->RSSetViewports(1, &dx_viewport)
    cmd.handle->RSSetScissorRects(1, &scissor)
    cmd.handle->IASetPrimitiveTopology(.TRIANGLELIST)

    cmd.handle->SetGraphicsRootConstantBufferView(0, dx.resource_get_gpu_address(view.frame_constants[frame_slot]))
    asset_buffers_bind_indices(cmd)

    // The sky first, over the clear: everything else draws over it.
    if _, ok := render_sky_image(world.settings.sky); ok {
        cmd.handle->SetPipelineState(renderer_dx.sky.pso.handle)
        cmd.handle->DrawInstanced(3, 1, 0, 0)
    }
    // One range per blend, in EntityBlend order: everything opaque is in the depth buffer before anything blends.
    r := &world.render
    for blend in EntityBlend {
        if r.draw_count[blend] == 0 do continue
        cmd.handle->SetPipelineState(renderer_dx.scene[blend].pso.handle)
        cmd.handle->ExecuteIndirect(renderer_dx.indirect_sig.handle, r.draw_count[blend], r.draw_cmd[frame_slot].handle, u64(r.draw_first[blend]) * size_of(d3d12.DRAW_INDEXED_ARGUMENTS), nil, 0)
    }
}

// Target → shader resource, so the UI pass can sample it into an ImGui window.
render_view_end :: proc(view: ^Render_View) {
    dx.texture_transition(renderer_dx.cmd_gfx, &view.target.tex, {.PIXEL_SHADING}, {.SHADER_RESOURCE}, .SHADER_RESOURCE)
}

// The view's background: its world's settings.background, linear scene light like everything the scene
// draws, so the post pass gives it exposure, the tonemap and the dither too. Nothing reads the alpha. It's
// also the target's optimized clear value, so when it changes the target is recreated
// (render_view_needs_rebuild) rather than cleared to a mismatched colour.
render_view_clear_color :: proc(w: ^World) -> [4]f32 {
    bg := w.settings.background
    return {bg.r, bg.g, bg.b, 1}
}

// True when the target must be recreated before drawing: a new size, a new scene scale (from the size,
// the render mode or the retro lines), a new render mode (post targets), or a new background colour. Recreating waits for the GPU, so the caller does it
// between frames (renderer_dx_resize_view).
render_view_needs_rebuild :: proc(view: ^Render_View, size: uvec2) -> bool {
    return size.x != view.target.width || size.y != view.target.height ||
        view.target.scene_scale != render_view_scene_scale(view, size) ||
        view.target.post_targets != (view.mode == .Retro) ||
        view.target.clear_color != render_view_clear_color(view.world)
}

