package blimp

import "core:log"
import "core:math"
import "core:math/linalg"
import "vendor:directx/d3d12"
import "dx"

// Realtime shadow maps (docs/rendering.md, Shadows): hard, point sampled, one depth texture array per world.
// Every shadow is a slice with its own camera: a directional, spot or cylinder light takes one, a point
// light six (a cube's faces, +X −X +Y −Y +Z −Z; the scene shader picks the face). Each frame the shadow
// pass draws the world's drawn geometry into every slice in use; the scene pass then compares against
// one texel per light. Lights claim slices in entity order until MAX_SHADOW_SLICES runs out; the rest
// light unshadowed.

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
    _padding: [256 - 80]byte,
}
#assert(size_of(Shadow_View) == 256)

Render_Shadows :: struct {
    shader: dx.Compiled_Shader,
    pso:    dx.Pipeline_State,
}
render_shadows: Render_Shadows

render_shadows_init :: proc() {
    render_shadows.shader = dx.slang_compiler_compile_shader(renderer_dx.slang_compiler, "shadow", "vert_main", "")

    opts := dx.PIPELINE_OPTIONS_DEFAULT
    opts.cull_mode  = .NONE      // single-sided walls must still block light from behind
    opts.rtv_format = .UNKNOWN   // depth only
    opts.depth_bias = SHADOW_DEPTH_BIAS
    opts.slope_bias = SHADOW_SLOPE_BIAS
    render_shadows.pso = dx.pipeline_create_graphics_pso(renderer_dx.render_context, renderer_dx.root_signature, render_shadows.shader, opts)
}

render_shadows_shutdown :: proc() {
    dx.pipeline_destroy_pso(render_shadows.pso)
    dx.slang_compiler_destroy_shader(render_shadows.shader)
}

// ============================ Per world ============================

world_shadows_create :: proc(w: ^World) {
    r := &w.render
    r.shadow_cameras = make([dynamic]mat4, 0, MAX_SHADOW_SLICES, app.allocators.perm)
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
    delete(r.shadow_cameras)
}

// Gives `light` (from entity `e`, which has `shadow` set) its slices: appends its cameras to the world's
// list and points the light at the first. Out of slices → it stays SHADOW_NONE, logged once per change in
// how many lights miss out (buffers_build_scene runs every frame).
light_shadow_assign :: proc(r: ^World_Render, e: ^Entity, light: ^GPU_Light) {
    cameras, count, texel := light_shadow_cameras(e)
    if len(r.shadow_cameras) + count > MAX_SHADOW_SLICES {
        r.shadow_missed += 1
        return
    }
    light.shadow_slice = u32(len(r.shadow_cameras))
    light.shadow_texel = texel
    append(&r.shadow_cameras, ..cameras[:count])
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
// perspective ones (spot, point), which the shader scales by distance.
//   Directional — a box centred on the entity: size.x × size.y across, size.z deep, looking down its +Z
//   Cylinder    — its beam: 2 × radius across, from the disc out to range.y
//   Spot        — its cone: a square frustum of the full fov, out to range.y
//   Point       — six 90° frusta along the world axes, out to range.y (the entity's rotation doesn't matter)
light_shadow_cameras :: proc(e: ^Entity) -> (cameras: [6]mat4, count: int, texel: f32) {
    view := linalg.inverse(linalg.matrix4_from_trs_f32(e.position, e.rotation, 1))
    far  := max(e.range.y, SHADOW_NEAR * 2)
    switch e.light_type {
    case .None:
    case .Directional:
        h := linalg.max(e.size, 0.01) * 0.5
        cameras[0] = orthographic_projection(-h.x, h.x, -h.y, h.y, h.z, -h.z) * view   // near and far swapped: reversed-Z
        return cameras, 1, 2 * max(h.x, h.y) / SHADOW_MAP_SIZE
    case .Cylinder:
        r := max(e.radius, 0.01)
        cameras[0] = orthographic_projection(-r, r, -r, r, far, 0) * view
        return cameras, 1, 2 * r / SHADOW_MAP_SIZE
    case .Spot:
        fov := clamp(math.to_radians(e.fov), 0.01, math.to_radians(f32(170)))
        cameras[0] = perspective_projection(fov, 1, far, SHADOW_NEAR) * view
        return cameras, 1, 2 * math.tan(fov * 0.5) / SHADOW_MAP_SIZE
    case .Point:
        proj := perspective_projection(math.PI / 2, 1, far, SHADOW_NEAR)
        dirs := [6]vec3{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
        for dir, i in dirs {
            up := abs(dir.y) > 0 ? vec3{0, 0, 1} : vec3{0, 1, 0}
            cameras[i] = proj * linalg.inverse(look_at_matrix(e.position, e.position + dir, up))
        }
        return cameras, 6, 2.0 / SHADOW_MAP_SIZE   // tan(45°) = 1
    }
    return
}

// Writes this frame's slice cameras into the mapped Shadow_View buffer for `frame_slot`, with the world's
// buffer slots for the same flight slot.
world_shadows_upload :: proc(w: ^World, frame_slot: u64) {
    r := &w.render
    views := ([^]Shadow_View)(r.shadow_views_ptr[frame_slot])
    for m, i in r.shadow_cameras {
        views[i] = {
            view_proj                 = m,
            transform_buffer_slot     = r.transform[frame_slot].resource_view.heap_slot,
            mesh_instance_buffer_slot = r.mesh_instance[frame_slot].resource_view.heap_slot,
            mesh_buffer_slot          = asset_buffers.mesh_buffer.resource_view.heap_slot,
            position_buffer_slot      = asset_buffers.position_buffer.resource_view.heap_slot,
        }
    }
}

// gfx: draws the world's drawn geometry into each slice in use, then leaves the map shader-readable for the
// scene passes. Every drawn mesh casts; there's no per-entity opt-out yet and no caching of static maps.
render_shadows_draw :: proc(w: ^World, frame_slot: u64) {
    r   := &w.render
    cmd := renderer_dx.cmd_gfx
    if len(r.shadow_cameras) > 0 {
        dx.texture_transition(cmd, &r.shadow_map, {.DEPTH_STENCIL}, {.DEPTH_STENCIL_WRITE}, .DEPTH_STENCIL_WRITE)

        dx.descriptor_heap_bind(cmd, {renderer_dx.resource_heap, renderer_dx.sampler_heap})
        cmd.handle->SetGraphicsRootSignature(renderer_dx.root_signature.handle)
        cmd.handle->SetPipelineState(render_shadows.pso.handle)
        dx_viewport := d3d12.VIEWPORT{Width = SHADOW_MAP_SIZE, Height = SHADOW_MAP_SIZE, MaxDepth = 1.0}
        scissor     := d3d12.RECT{right = SHADOW_MAP_SIZE, bottom = SHADOW_MAP_SIZE}
        cmd.handle->RSSetViewports(1, &dx_viewport)
        cmd.handle->RSSetScissorRects(1, &scissor)
        cmd.handle->IASetPrimitiveTopology(.TRIANGLELIST)
        cmd.handle->IASetIndexBuffer(&d3d12.INDEX_BUFFER_VIEW{BufferLocation = dx.resource_get_gpu_address(asset_buffers.index_buffer.resource), SizeInBytes = u32(len(asset_system.vertex_indices) * size_of(u32)), Format = .R32_UINT})

        views_va := dx.resource_get_gpu_address(r.shadow_views[frame_slot])
        for i in 0..<len(r.shadow_cameras) {
            dsv := r.shadow_dsv[i].cpu_handle
            cmd.handle->OMSetRenderTargets(0, nil, false, &dsv)
            cmd.handle->ClearDepthStencilView(dsv, {.DEPTH}, 0.0, 0, 0, nil)   // reversed-Z: 0 = far, nothing casts
            cmd.handle->SetGraphicsRootConstantBufferView(0, views_va + d3d12.GPU_VIRTUAL_ADDRESS(i * size_of(Shadow_View)))
            cmd.handle->ExecuteIndirect(renderer_dx.indirect_sig.handle, u32(len(r.draw_cmd_data)), r.draw_cmd[frame_slot].handle, 0, nil, 0)
        }
    }
    dx.texture_transition(cmd, &r.shadow_map, {.PIXEL_SHADING}, {.SHADER_RESOURCE}, .SHADER_RESOURCE)
}
