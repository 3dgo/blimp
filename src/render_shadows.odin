package blimp

import "core:log"
import "core:math"
import "core:math/linalg"
import "vendor:directx/d3d12"
import "dx"

// Realtime shadow maps (claude/rendering.md, Shadows): hard, point sampled, one depth texture array per world.
// Every shadow is a slice with its own camera: a directional, spot or cylinder light takes one, a point
// light six (a cube's faces, +X −X +Y −Y +Z −Z; the scene shader picks the face). Each frame the shadow
// pass draws the world's drawn geometry into every slice in use; the scene pass then compares against
// one texel per light. Lights claim slices in entity order until MAX_SHADOW_SLICES runs out; the rest
// light unshadowed. Slices are cached: redrawn only when their camera or the casters change
// (render_shadows_draw).

SHADOW_MAP_SIZE   :: 512   // texels per side; SHADOW_MAP_SIZE in common.slang
MAX_SHADOW_SLICES :: 32    // per world: 32 × 512² × 4 B = 32 MB
SHADOW_NEAR       :: 0.05  // near plane of the perspective (spot, point) shadow cameras
SHADOW_NONE       :: max(u32)   // GPU_Light.shadow_slice of a light without a shadow map

// Depth bias for the shadow pass's casters, pushed away from the light (reversed-Z: negative). The scene
// shader also moves each receiver along its normal by ~a texel (light.shadow_texel), which does most of the work.
SHADOW_DEPTH_BIAS :: -16
SHADOW_SLOPE_BIAS :: -1.5

// One slice's camera, 256 bytes so the shadow pass can bind each as its root CBV (shadow.slang's
// ShadowConstants), and the scene pass reads the same buffer as StructuredBuffer<ShadowView>.
Shadow_View :: struct {
    view_proj: mat4,   // world → the slice's clip space, reversed-Z
    transform_buffer_slot:     u32,
    mesh_instance_buffer_slot: u32,
    mesh_buffer_slot:          u32,
    position_buffer_slot:      u32,
    skin_buffer_slot:          u32,
    bone_buffer_slot:          u32,
    // For the Shadow Maps window's pass (render_shadows_debug_draw) only.
    shadow_map_slot: u32,
    slice:           u32,
    near, far:       f32,   // perspective planes, to show depth linearly; far 0 = orthographic (already linear)
    _padding: [256 - 104]byte,
}
#assert(size_of(Shadow_View) == 256)

// One slice in use this frame (World_Render.shadow_slices): its camera, plus what the Shadow Maps window
// shows. The light's name is copied, since the window draws from last frame's list.
Shadow_Slice :: struct {
    camera:     mat4,
    far:        f32,   // perspective (spot, point): the far plane; 0 = orthographic
    texel:      f32,   // world size of one texel (at 1 unit for spot and point)
    light:      sbuf64,
    light_type: EntityLightType,
    face:       u8,    // point light: 0..5 = +X −X +Y −Y +Z −Z
}

// The Shadow Maps window's atlas (render_shadows_debug_draw): each slice as a SHADOW_DEBUG_TILE² tile,
// SHADOW_DEBUG_COLS across. SHADOW_DEBUG_TILE in shadow.slang.
SHADOW_DEBUG_TILE :: 256
SHADOW_DEBUG_COLS :: 8
SHADOW_DEBUG_ROWS :: (MAX_SHADOW_SLICES + SHADOW_DEBUG_COLS - 1) / SHADOW_DEBUG_COLS

Render_Shadows :: struct {
    pipeline: Shader_Pipeline,
    debug:    Shader_Pipeline,   // one slice as grey depth into its atlas tile
    // The Shadow Maps window: the world it shows, set by the UI each frame it's open and cleared once drawn
    // (nil = closed, nothing drawn). The atlas is made on first use and kept.
    debug_world:     ^World,
    debug_atlas:     dx.Resource,
    debug_rtv_heap:  dx.Descriptor_Heap,
    debug_rtv:       dx.Resource_View,
    debug_atlas_ui:  dx.Resource_View,   // its SRV in the ImGui heap
}
render_shadows: Render_Shadows

render_shadows_init :: proc() {
    opts := dx.PIPELINE_OPTIONS_DEFAULT
    opts.cull_mode  = .NONE      // single-sided walls must still block light from behind
    opts.rtv_format = .UNKNOWN   // depth only
    opts.depth_bias = SHADOW_DEPTH_BIAS
    opts.slope_bias = SHADOW_SLOPE_BIAS
    render_shadows.pipeline = shader_pipeline_create("shadow", "vert_main", "", opts)

    debug := dx.PIPELINE_OPTIONS_DEFAULT
    debug.cull_mode   = .NONE
    debug.depth_test  = false
    debug.depth_write = false
    debug.rtv_format  = .R8G8B8A8_UNORM
    debug.dsv_format  = .UNKNOWN
    render_shadows.debug = shader_pipeline_create("shadow", "vert_debug", "frag_debug", debug)
}

render_shadows_shutdown :: proc() {
    shader_pipeline_destroy(render_shadows.pipeline)
    shader_pipeline_destroy(render_shadows.debug)
    s := &render_shadows
    if s.debug_atlas.handle != nil {
        dx.descriptor_heap_free(&renderer_dx.ui_heap, s.debug_atlas_ui.heap_slot)
        dx.descriptor_heap_destroy(s.debug_rtv_heap)
        dx.texture2d_destroy(s.debug_atlas)
    }
}

// ============================ Per world ============================

world_shadows_create :: proc(w: ^World) {
    r := &w.render
    r.shadow_slices = make([dynamic]Shadow_Slice, 0, MAX_SHADOW_SLICES, app.allocators.perm)
    r.shadow_map = dx.texture2d_create(renderer_dx.render_context, {format = .R32_TYPELESS,
        width = SHADOW_MAP_SIZE, height = SHADOW_MAP_SIZE, mip_levels = 1, array_size = MAX_SHADOW_SLICES, heap_type = .DEFAULT,
        flags = {.ALLOW_DEPTH_STENCIL}, clear_value = &{Format = .D32_FLOAT, DepthStencil = {Depth = 0.0}}})
    r.shadow_map_srv = dx.descriptor_heap_register_srv(renderer_dx.render_context, &renderer_dx.resource_heap, r.shadow_map, .R32_FLOAT)
    r.shadow_dsv_heap = dx.descriptor_heap_create(renderer_dx.render_context, {type = .DSV, cap = MAX_SHADOW_SLICES}, app.allocators.perm)
    for i in 0..<u32(MAX_SHADOW_SLICES) {
        r.shadow_dsv[i] = dx.descriptor_heap_register_dsv(renderer_dx.render_context, &r.shadow_dsv_heap, r.shadow_map, .D32_FLOAT, i)
    }
    for i in 0..<FRAMES_IN_FLIGHT {
        // UPLOAD and mapped, like the draw commands: written in place, read by the GPU without a copy.
        r.shadow_views[i]     = dx.buffer_create(renderer_dx.render_context, {element_size = size_of(Shadow_View), num_elements = MAX_SHADOW_SLICES, heap_type = .UPLOAD})
        r.shadow_views_ptr[i] = dx.buffer_map(r.shadow_views[i])
        r.shadow_views_srv[i] = dx.descriptor_heap_register_srv(renderer_dx.render_context, &renderer_dx.resource_heap, r.shadow_views[i])
    }
}

world_shadows_destroy :: proc(w: ^World) {
    r := &w.render
    for i in 0..<FRAMES_IN_FLIGHT {
        dx.descriptor_heap_free(&renderer_dx.resource_heap, r.shadow_views_srv[i].heap_slot)
        dx.buffer_unmap(r.shadow_views[i])
        dx.buffer_destroy(r.shadow_views[i])
    }
    dx.descriptor_heap_destroy(r.shadow_dsv_heap)
    dx.descriptor_heap_free(&renderer_dx.resource_heap, r.shadow_map_srv.heap_slot)
    dx.texture2d_destroy(r.shadow_map)
    delete(r.shadow_slices)
}

// Gives `light` (from entity `e`, which has `shadow` set) its slices: appends its cameras to the world's
// list and points the light at the first. Out of slices → it stays SHADOW_NONE, logged once per change in
// how many lights miss out (buffers_build_scene runs every frame).
light_shadow_assign :: proc(r: ^World_Render, e: ^Entity, light: ^GPU_Light) {
    cameras, count, texel, far := light_shadow_cameras(e)
    if len(r.shadow_slices) + count > MAX_SHADOW_SLICES {
        r.shadow_missed += 1
        return
    }
    light.shadow_slice = u32(len(r.shadow_slices))
    light.shadow_texel = texel
    for camera, face in cameras[:count] {
        append(&r.shadow_slices, Shadow_Slice{camera = camera, far = far, texel = texel, light = e.name, light_type = e.light_type, face = u8(face)})
    }
}

// Called after every light has had light_shadow_assign this frame.
light_shadow_report :: proc(r: ^World_Render) {
    if r.shadow_missed != r.shadow_missed_logged && r.shadow_missed > 0 {
        log.warnf("%d shadowed lights got no shadow map: MAX_SHADOW_SLICES (%d) used up (a point light takes 6)", r.shadow_missed, MAX_SHADOW_SLICES)
    }
    r.shadow_missed_logged = r.shadow_missed
}

// The shadow cameras of light `e` (view-projections, reversed-Z), how many there are, and the world size of
// one shadow texel: absolute for the orthographic ones (directional, cylinder), at 1 unit away for the
// perspective ones (spot, point), which the shader scales by distance; and the perspective ones' far plane
// (0 for orthographic).
//   Directional — a box centred on the entity: size.x × size.y across, size.z deep, looking down its +Z
//   Cylinder    — its beam: 2 × radius across, from the disc out to range.y
//   Spot        — its cone: a square frustum of the full fov, out to range.y
//   Point       — six 90° frusta along the world axes, out to range.y (the entity's rotation doesn't matter)
light_shadow_cameras :: proc(e: ^Entity) -> (cameras: [6]mat4, count: int, texel: f32, perspective_far: f32) {
    view := entity_camera_view(e)   // looking down its +Z, like a camera entity
    far  := max(e.range.y, SHADOW_NEAR * 2)
    switch e.light_type {
    case .None:
    case .Directional:
        h := linalg.max(e.size, 0.01) * 0.5
        cameras[0] = orthographic_projection(-h.x, h.x, -h.y, h.y, h.z, -h.z) * view   // near and far swapped: reversed-Z
        return cameras, 1, 2 * max(h.x, h.y) / SHADOW_MAP_SIZE, 0
    case .Cylinder:
        r := max(e.radius, 0.01)
        cameras[0] = orthographic_projection(-r, r, -r, r, far, 0) * view
        return cameras, 1, 2 * r / SHADOW_MAP_SIZE, 0
    case .Spot:
        fov := clamp(math.to_radians(e.fov), 0.01, math.to_radians(f32(170)))
        cameras[0] = perspective_projection(fov, 1, far, SHADOW_NEAR) * view
        return cameras, 1, 2 * math.tan(fov * 0.5) / SHADOW_MAP_SIZE, far
    case .Point:
        proj := perspective_projection(math.PI / 2, 1, far, SHADOW_NEAR)
        dirs := [6]vec3{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
        for dir, i in dirs {
            up := abs(dir.y) > 0 ? vec3{0, 0, 1} : vec3{0, 1, 0}
            cameras[i] = proj * linalg.inverse(look_at_matrix(e.position, e.position + dir, up))
        }
        return cameras, 6, 2.0 / SHADOW_MAP_SIZE, far   // tan(45°) = 1
    }
    return
}

// Writes this frame's slice cameras into the mapped Shadow_View buffer for `frame_slot`, with the world's
// buffer slots for the same flight slot.
world_shadows_upload :: proc(w: ^World, frame_slot: u64) {
    r := &w.render
    views := ([^]Shadow_View)(r.shadow_views_ptr[frame_slot])
    for s, i in r.shadow_slices {
        views[i] = {
            view_proj                 = s.camera,
            transform_buffer_slot     = r.transform[frame_slot].resource_view.heap_slot,
            mesh_instance_buffer_slot = r.mesh_instance[frame_slot].resource_view.heap_slot,
            mesh_buffer_slot          = asset_buffers.mesh_buffer.resource_view.heap_slot,
            position_buffer_slot      = asset_buffers.position_buffer.resource_view.heap_slot,
            skin_buffer_slot          = asset_buffers.skin_buffer.resource_view.heap_slot,
            bone_buffer_slot          = r.bones[frame_slot].resource_view.heap_slot,
            shadow_map_slot           = r.shadow_map_srv.heap_slot,
            slice                     = u32(i),
            near                      = s.far > 0 ? SHADOW_NEAR : 0,
            far                       = s.far,
        }
    }
}

// gfx: draws the world's drawn geometry into each slice that needs it, then leaves the map shader-readable
// for the scene passes. Every drawn Opaque or Cutout mesh casts; there's no per-entity opt-out yet.
//
// Static caching: the map keeps its depth between frames, so a slice is redrawn only when its camera changed
// (the light moved, or the slice now belongs to another light) or anything that casts changed since the
// slices were last drawn (r.shadow_casters, hashed by buffers_build_scene). A level standing still draws no
// shadow maps at all; one moving light redraws only its own slices; anything moving redraws them all.
render_shadows_draw :: proc(w: ^World, frame_slot: u64) {
    r   := &w.render
    cmd := renderer_dx.cmd_gfx
    if r.shadow_casters != r.shadow_casters_drawn {
        r.shadow_drawn = {}
        r.shadow_casters_drawn = r.shadow_casters
    }
    dirty: [MAX_SHADOW_SLICES]bool
    any_dirty := false
    for s, i in r.shadow_slices {
        held, ok := r.shadow_drawn[i].?
        dirty[i] = !ok || held != s.camera
        any_dirty ||= dirty[i]
    }
    if any_dirty {
        dx.texture_transition(cmd, &r.shadow_map, {.DEPTH_STENCIL}, {.DEPTH_STENCIL_WRITE}, .DEPTH_STENCIL_WRITE)

        dx.descriptor_heap_bind(cmd, {renderer_dx.resource_heap, renderer_dx.sampler_heap})
        cmd.handle->SetGraphicsRootSignature(renderer_dx.root_signature.handle)
        cmd.handle->SetPipelineState(render_shadows.pipeline.pso.handle)
        dx_viewport := d3d12.VIEWPORT{Width = SHADOW_MAP_SIZE, Height = SHADOW_MAP_SIZE, MaxDepth = 1.0}
        scissor     := d3d12.RECT{right = SHADOW_MAP_SIZE, bottom = SHADOW_MAP_SIZE}
        cmd.handle->RSSetViewports(1, &dx_viewport)
        cmd.handle->RSSetScissorRects(1, &scissor)
        cmd.handle->IASetPrimitiveTopology(.TRIANGLELIST)
        asset_buffers_bind_indices(cmd)

        views_va := dx.resource_get_gpu_address(r.shadow_views[frame_slot])
        // Opaque and Cutout cast (the first two ranges; a cutout casts its whole quad, this pass has no pixel
        // shader to cut it), Alpha and Additive don't.
        #assert(EntityBlend.Opaque == EntityBlend(0) && EntityBlend.Cutout == EntityBlend(1))
        casters := r.draw_count[.Opaque] + r.draw_count[.Cutout]
        for s, i in r.shadow_slices {
            if !dirty[i] do continue
            r.shadow_drawn[i] = s.camera
            dsv := r.shadow_dsv[i].cpu_handle
            cmd.handle->OMSetRenderTargets(0, nil, false, &dsv)
            cmd.handle->ClearDepthStencilView(dsv, {.DEPTH}, 0.0, 0, 0, nil)   // reversed-Z: 0 = far, nothing casts
            cmd.handle->SetGraphicsRootConstantBufferView(0, views_va + d3d12.GPU_VIRTUAL_ADDRESS(i * size_of(Shadow_View)))
            if casters == 0 do continue   // cleared map is correct; a zero-count ExecuteIndirect draws a debug-layer warning
            cmd.handle->ExecuteIndirect(renderer_dx.indirect_sig.handle, casters, r.draw_cmd[frame_slot].handle, 0, nil, 0)
        }
    }
    dx.texture_transition(cmd, &r.shadow_map, {.PIXEL_SHADING}, {.SHADER_RESOURCE}, .SHADER_RESOURCE)
}

// gfx, after render_shadows_draw, while the Shadow Maps window shows `w`: each slice in use as grey depth
// into its tile of the window's atlas (white at the light, black far away, dark blue where nothing casts).
render_shadows_debug_draw :: proc(w: ^World, frame_slot: u64) {
    s   := &render_shadows
    cmd := renderer_dx.cmd_gfx
    if s.debug_atlas.handle == nil {
        s.debug_atlas = dx.texture2d_create(renderer_dx.render_context, {format = .R8G8B8A8_UNORM,
            width = SHADOW_DEBUG_COLS * SHADOW_DEBUG_TILE, height = SHADOW_DEBUG_ROWS * SHADOW_DEBUG_TILE,
            mip_levels = 1, heap_type = .DEFAULT, flags = {.ALLOW_RENDER_TARGET}})
        s.debug_rtv_heap = dx.descriptor_heap_create(renderer_dx.render_context, {type = .RTV, cap = 1}, app.allocators.perm)
        s.debug_rtv      = dx.descriptor_heap_register_rtv(renderer_dx.render_context, &s.debug_rtv_heap, s.debug_atlas)
        s.debug_atlas_ui = dx.descriptor_heap_register_srv(renderer_dx.render_context, &renderer_dx.ui_heap, s.debug_atlas)
    }
    dx.texture_transition(cmd, &s.debug_atlas, {.RENDER_TARGET}, {.RENDER_TARGET}, .RENDER_TARGET)
    rtv := s.debug_rtv.cpu_handle
    cmd.handle->OMSetRenderTargets(1, &rtv, false, nil)
    dx.descriptor_heap_bind(cmd, {renderer_dx.resource_heap, renderer_dx.sampler_heap})
    cmd.handle->SetGraphicsRootSignature(renderer_dx.root_signature.handle)
    cmd.handle->SetPipelineState(s.debug.pso.handle)
    cmd.handle->IASetPrimitiveTopology(.TRIANGLELIST)
    views_va := dx.resource_get_gpu_address(w.render.shadow_views[frame_slot])
    for _, i in w.render.shadow_slices {
        x, y := f32(i % SHADOW_DEBUG_COLS * SHADOW_DEBUG_TILE), f32(i / SHADOW_DEBUG_COLS * SHADOW_DEBUG_TILE)
        dx_viewport := d3d12.VIEWPORT{TopLeftX = x, TopLeftY = y, Width = SHADOW_DEBUG_TILE, Height = SHADOW_DEBUG_TILE, MaxDepth = 1.0}
        scissor     := d3d12.RECT{left = i32(x), top = i32(y), right = i32(x) + SHADOW_DEBUG_TILE, bottom = i32(y) + SHADOW_DEBUG_TILE}
        cmd.handle->RSSetViewports(1, &dx_viewport)
        cmd.handle->RSSetScissorRects(1, &scissor)
        cmd.handle->SetGraphicsRootConstantBufferView(0, views_va + d3d12.GPU_VIRTUAL_ADDRESS(i * size_of(Shadow_View)))
        cmd.handle->DrawInstanced(3, 1, 0, 0)
    }
    dx.texture_transition(cmd, &s.debug_atlas, {.PIXEL_SHADING}, {.SHADER_RESOURCE}, .SHADER_RESOURCE)
}
