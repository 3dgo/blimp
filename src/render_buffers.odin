package blimp

import "core:log"
import "core:mem"
import "core:math"
import hm "core:container/handle_map"
import "vendor:directx/d3d12"
import "vendor:directx/dxgi"
import "dx"

// GPU buffer storage for the renderer, split by owner/lifetime:
//   Asset_Buffers  — shared static asset data (geometry, materials, textures); one copy, engine-wide.
//   World_Render   — a world's per-frame draw mirror (transforms, instances, draw cmds); one per World.
//   (Per-view frame constants + render target live in Render_View, render_view.odin.)
//
// Division of labour with renderer_dx: this file owns the *resources* — their layout,
// sizing, creation/teardown, the CPU-side staging arrays, turning the entity list into
// those arrays (buffers_build_scene), and the primitive that stages bytes into a resource
// (buffers_resource_copy). The renderer owns the *frame timeline* — when each upload
// happens, on which queue, and the barriers/fences that pair with it — so the per-frame
// copies are driven from renderer_dx_update using the primitives here, right next to the
// transitions they depend on. The one exception is buffers_upload_static, a one-time init
// upload with no per-frame barrier pairing, which is cohesive enough to own outright.

// Fixed capacity for a world's per-frame-rebuilt entity buffers (transforms, instances, draw
// commands). Sized once per world in world_render_create; spawning is bounded by this and the
// entity map cap.
MAX_MESH_INSTANCES :: 4 * MAX_ENTITIES   // an entity expands to one instance per mesh of its model

// Shared, static, asset-derived GPU buffers — one copy for the whole engine, read by every
// world and view. Per-world draw data lives in World_Render; per-view constants in Render_View.
Asset_Buffers :: struct {
    mesh_buffer: Resource_With_Upload,

    index_buffer: Resource_With_Upload,
    position_buffer: Resource_With_Upload,
    attribute_buffer: Resource_With_Upload,

    material_buffer: Resource_With_Upload,
    material_buffer_data: [dynamic]Material,

    texture_buffers: [dynamic]Resource_With_Upload,
    sampler: dx.Resource_View,
}
asset_buffers: Asset_Buffers

// A world's GPU draw mirror: its entities expanded into transforms, mesh instances, and draw
// commands, rebuilt from the entity list each frame (buffers_build_scene). Per-flight so the GPU
// can read last frame's copy while the CPU writes this one. Owned by the World and shared by
// every view looking at that world (built once per frame, not per view).
World_Render :: struct {
    transform:     [FRAMES_IN_FLIGHT]Resource_With_Upload,
    transform_data: [dynamic]mat4,

    mesh_instance: [FRAMES_IN_FLIGHT]Resource_With_Upload,
    mesh_instance_data: [dynamic]Mesh_Instance_Data,

    lights: [FRAMES_IN_FLIGHT]Resource_With_Upload,
    lights_data: [dynamic]GPU_Light,

    draw_cmd:     [FRAMES_IN_FLIGHT]dx.Resource,
    draw_cmd_ptr: [FRAMES_IN_FLIGHT]rawptr,
    draw_cmd_data: [dynamic]d3d12.DRAW_INDEXED_ARGUMENTS,
}

// One entity-mesh pair. The shader indexes it (via SV_StartInstanceLocation) to reach the
// entity's transform and the mesh's material. Mirrors the MeshInstance struct in the shader.
Mesh_Instance_Data :: struct {
    transform: u32,
    mesh: u32,
    material: u32,
}

// One light entity, rebuilt each frame. Mirrors the Light struct in the shader.
GPU_Light :: struct {
    position: vec3, type: u32,         // u32(EntityLightType)
    direction: vec3, radius: f32,      // entity +Z (also the cylinder's axis); range.y, where the falloff reaches zero
    color: vec3, cos_outer: f32,       // linear colour; cos(fov / 2) (spot)
    intensity: f32, cos_inner: f32,    // cos(inner_fov / 2) (spot)
    inner_radius: f32, falloff: u32,   // range.x; u32(EntityLightFalloff)
    beam_radius: f32, beam_inner: f32, // radius, inner_radius (cylinder)
    _pad: [2]f32,
}
#assert(size_of(GPU_Light) == 80)

// A GPU resource paired with the CPU-writable upload buffer that stages data into it.
Resource_With_Upload :: struct {
    resource: dx.Resource,
    resource_view: dx.Resource_View,
    upload: dx.Resource,
    upload_ptr: rawptr,
}

// ============================ Lifetime ============================

// Creates the shared, static, asset-derived buffers once at init.
asset_buffers_create :: proc() {
    asset_buffers.mesh_buffer      = buffers_resource_create(size_of(Mesh), u32(len(asset_system.meshes)), &renderer_dx.resource_heap)
    asset_buffers.index_buffer     = buffers_resource_create(size_of(u32), u32(len(asset_system.vertex_indices)), &renderer_dx.resource_heap)
    asset_buffers.position_buffer  = buffers_resource_create(size_of(vec3), u32(len(asset_system.vertex_positions)), &renderer_dx.resource_heap)
    asset_buffers.attribute_buffer = buffers_resource_create(size_of(Vertex_Attributes), u32(len(asset_system.vertex_attributes)), &renderer_dx.resource_heap)

    for img in asset_system.images {
        append(&asset_buffers.texture_buffers, buffers_texture_create(img.width, img.height, dx_format(img.format)))
    }

    // Material table: asset material image indices are resolved to bindless heap slots here.
    asset_buffers.material_buffer_data = make([dynamic]Material, app.allocators.perm)
    for mat in asset_system.materials {
        append(&asset_buffers.material_buffer_data, Material {
            color = mat.color,
            color_tex = asset_buffers.texture_buffers[mat.color_tex].resource_view.heap_slot,
        })
    }
    asset_buffers.material_buffer = buffers_resource_create(size_of(Material), u32(len(asset_buffers.material_buffer_data)), &renderer_dx.resource_heap)

    asset_buffers.sampler = dx.descriptor_heap_register_sampler(renderer_dx.render_context, &renderer_dx.sampler_heap, {
        Filter = .MIN_MAG_MIP_LINEAR,
        AddressU = .WRAP, AddressV = .WRAP, AddressW = .WRAP,
        ComparisonFunc = .NEVER, MaxLOD = max(f32),
    })
}

asset_buffers_destroy :: proc() {
    for tex in asset_buffers.texture_buffers {
        dx.descriptor_heap_free(&renderer_dx.resource_heap, tex.resource_view.heap_slot)
        buffers_resource_destroy(tex)
    }
    dx.descriptor_heap_free(&renderer_dx.resource_heap, asset_buffers.sampler.heap_slot)
    delete(asset_buffers.texture_buffers)

    buffers_resource_destroy(asset_buffers.material_buffer)
    buffers_resource_destroy(asset_buffers.attribute_buffer)
    buffers_resource_destroy(asset_buffers.position_buffer)
    buffers_resource_destroy(asset_buffers.index_buffer)
    buffers_resource_destroy(asset_buffers.mesh_buffer)
    delete(asset_buffers.material_buffer_data)
}

// Creates a world's GPU draw mirror: per-flight transform/mesh-instance (copy-queue staged) and
// draw-command (UPLOAD, read directly by ExecuteIndirect) buffers, plus the CPU staging arrays
// that buffers_build_scene refills each frame. Call once per world, after the renderer's heaps exist.
world_render_create :: proc(world: ^World) {
    r := &world.render
    r.draw_cmd_data      = make([dynamic]d3d12.DRAW_INDEXED_ARGUMENTS, 0, MAX_MESH_INSTANCES, app.allocators.perm)
    r.transform_data     = make([dynamic]mat4, 0, MAX_MESH_INSTANCES, app.allocators.perm)
    r.mesh_instance_data = make([dynamic]Mesh_Instance_Data, 0, MAX_MESH_INSTANCES, app.allocators.perm)
    r.lights_data        = make([dynamic]GPU_Light, 0, MAX_LIGHTS, app.allocators.perm)

    for i in 0..<FRAMES_IN_FLIGHT {
        r.draw_cmd[i]     = dx.buffer_create(renderer_dx.render_context, {element_size = size_of(d3d12.DRAW_INDEXED_ARGUMENTS), num_elements = MAX_MESH_INSTANCES, heap_type = .UPLOAD})
        r.draw_cmd_ptr[i] = dx.buffer_map(r.draw_cmd[i])

        r.transform[i]     = buffers_resource_create(size_of(mat4), MAX_MESH_INSTANCES, &renderer_dx.resource_heap)
        r.mesh_instance[i] = buffers_resource_create(size_of(Mesh_Instance_Data), MAX_MESH_INSTANCES, &renderer_dx.resource_heap)
        r.lights[i]        = buffers_resource_create(size_of(GPU_Light), MAX_LIGHTS, &renderer_dx.resource_heap)
    }
}

world_render_destroy :: proc(world: ^World) {
    r := &world.render
    for i in 0..<FRAMES_IN_FLIGHT {
        // Worlds open and close at runtime now, so hand their bindless slots back to the heap.
        dx.descriptor_heap_free(&renderer_dx.resource_heap, r.transform[i].resource_view.heap_slot)
        dx.descriptor_heap_free(&renderer_dx.resource_heap, r.mesh_instance[i].resource_view.heap_slot)
        dx.descriptor_heap_free(&renderer_dx.resource_heap, r.lights[i].resource_view.heap_slot)
        buffers_resource_destroy(r.transform[i])
        buffers_resource_destroy(r.mesh_instance[i])
        buffers_resource_destroy(r.lights[i])
        dx.buffer_unmap(r.draw_cmd[i])
        dx.buffer_destroy(r.draw_cmd[i])
    }
    delete(r.draw_cmd_data)
    delete(r.transform_data)
    delete(r.mesh_instance_data)
    delete(r.lights_data)
}

// ============================ Scene build ============================

// Rebuilds the entity-derived CPU arrays (transforms, mesh instances, draw commands) from
// the current entity list. Clears and refills in place — no per-frame allocation. The
// renderer calls this each frame before staging the arrays to the GPU.
buffers_build_scene :: proc(world: ^World) {
    r := &world.render
    clear(&r.draw_cmd_data)
    clear(&r.transform_data)
    clear(&r.mesh_instance_data)
    clear(&r.lights_data)

    it := hm.iterator_make(&world.entities)
    for entity, _ in hm.iterate(&it) {
        if entity_drawn(entity) && entity.light_type != .None {
            light := GPU_Light {
                position = entity.position,
                type = u32(entity.light_type),
                direction = entity_forward(entity),
                color = entity.color,
                intensity = entity.intensity,
            }
            if entity.light_type != .Directional {
                // Inner clamped to outer; the shader keeps the fade width above zero, so inner == outer is
                // a hard edge, not a divide by zero.
                light.radius       = max(entity.range.y, 0.001)
                light.inner_radius = clamp(entity.range.x, 0, light.radius)
                light.falloff      = u32(entity.falloff)
            }
            #partial switch entity.light_type {
                case .Cylinder: {
                    light.beam_radius = max(entity.radius, 0)
                    light.beam_inner  = clamp(entity.inner_radius, 0, light.beam_radius)
                }
                case .Spot: {
                    // fov and inner_fov are full cone angles. Inner is clamped to outer; the shader keeps the
                    // fade width above zero, so inner == outer is a hard edge, not a divide by zero.
                    light.cos_outer = math.cos(math.to_radians(entity.fov) * 0.5)
                    light.cos_inner = math.cos(math.to_radians(min(entity.inner_fov, entity.fov)) * 0.5)
                }
            }

            if len(r.lights_data) < MAX_LIGHTS {
                append(&r.lights_data, light)
            } else {
                log.warnf("Too many lights, exceed MAX_LIGHTS count")
            }
        }

        // No model is fine (a camera or a light); a model key that doesn't resolve is a broken reference.
        model, ok := asset_system.models[entity.model]
        if !ok {
            if entity.model != "" do log.warnf("Entity references unknown model: %v", entity.model)
            continue
        }

        transform_idx := u32(len(r.transform_data))
        append(&r.transform_data, entity_transform(entity))
        drawn := entity_drawn(entity)   // instances for every entity, draw commands only for drawn ones

        for mesh_idx in model.meshes {
            if len(r.mesh_instance_data) >= MAX_MESH_INSTANCES {
                log.warnf("Exceeded MAX_MESH_INSTANCES (%v); remaining geometry not drawn", MAX_MESH_INSTANCES)
                return
            }
            mesh := asset_system.meshes[mesh_idx]

            instance_idx := u32(len(r.mesh_instance_data))
            append(&r.mesh_instance_data, Mesh_Instance_Data {
                transform = transform_idx,
                mesh = mesh_idx,
                material = mesh.material,
            })
            if !drawn do continue
            append(&r.draw_cmd_data, d3d12.DRAW_INDEXED_ARGUMENTS {
                IndexCountPerInstance = mesh.index_count,
                InstanceCount = 1,
                StartIndexLocation = mesh.index_offset,
                BaseVertexLocation = 0,
                StartInstanceLocation = instance_idx,
            })
        }
    }
}

// ============================ Uploads ============================

// One-time upload of the static, asset-derived buffers (geometry, tables, textures) via the
// copy queue. The entity buffers are staged per frame from renderer_dx_update instead.
buffers_upload_static :: proc(cmd: dx.Command_List) {
    buffers_resource_copy(cmd, &asset_buffers.mesh_buffer,      asset_system.meshes[:])
    buffers_resource_copy(cmd, &asset_buffers.index_buffer,     asset_system.vertex_indices[:])
    buffers_resource_copy(cmd, &asset_buffers.position_buffer,  asset_system.vertex_positions[:])
    buffers_resource_copy(cmd, &asset_buffers.attribute_buffer, asset_system.vertex_attributes[:])
    buffers_resource_copy(cmd, &asset_buffers.material_buffer,  asset_buffers.material_buffer_data[:])

    for img, i in asset_system.images {
        buffers_texture_copy(cmd, &asset_buffers.texture_buffers[i], img)
    }
}

// Records a copy of a CPU data slice through a resource's upload buffer into the resource
// itself, and leaves the resource in a copy-neutral (NO_ACCESS) state for the gfx queue to
// transition into a shader-readable one. This is the per-frame staging primitive.
buffers_resource_copy :: proc(cmd: dx.Command_List, buffer: ^Resource_With_Upload, data: []$T) {
    dx.buffer_transition(cmd, &buffer.resource, {.COPY}, {.COPY_DEST})
    mem.copy(buffer.upload_ptr, raw_data(data), len(data) * size_of(T))
    cmd.handle->CopyBufferRegion(buffer.resource.handle, 0, buffer.upload.handle, 0, u64(len(data) * size_of(T)))
    dx.buffer_transition(cmd, &buffer.resource, {}, {.NO_ACCESS})
}

// ====================== Frame timeline: per-world and shared stages ======================
// renderer_dx_update decides *when* these run; they group the uploads and barriers by owner so a
// frame stages each world once and transitions shared assets once, however many views draw them
// (the per-view share lives in render_view.odin). A new World_Render buffer goes in all three
// world_render_* procs.

// Rebuilds `world`'s draw mirror from its entities and stages it for `frame_slot`: transforms,
// mesh instances and lights through the copy queue; draw commands written straight into their
// mapped UPLOAD buffer (ExecuteIndirect reads it in place).
world_render_upload :: proc(world: ^World, frame_slot: u64) {
    r := &world.render
    buffers_build_scene(world)
    buffers_resource_copy(renderer_dx.cmd_copy, &r.transform[frame_slot],     r.transform_data[:])
    buffers_resource_copy(renderer_dx.cmd_copy, &r.mesh_instance[frame_slot], r.mesh_instance_data[:])
    buffers_resource_copy(renderer_dx.cmd_copy, &r.lights[frame_slot],        r.lights_data[:])
    mem.copy(r.draw_cmd_ptr[frame_slot], raw_data(r.draw_cmd_data), size_of(d3d12.DRAW_INDEXED_ARGUMENTS) * len(r.draw_cmd_data))
}

// gfx: the world's freshly staged buffers → shader-readable for this frame's scene passes.
world_render_begin :: proc(world: ^World, frame_slot: u64) {
    dx.buffer_transition(renderer_dx.cmd_gfx, &world.render.mesh_instance[frame_slot].resource, {.ALL_SHADING}, {.SHADER_RESOURCE})
    dx.buffer_transition(renderer_dx.cmd_gfx, &world.render.transform[frame_slot].resource,     {.ALL_SHADING}, {.SHADER_RESOURCE})
    dx.buffer_transition(renderer_dx.cmd_gfx, &world.render.lights[frame_slot].resource,        {.ALL_SHADING}, {.SHADER_RESOURCE})
}

// gfx: back to NO_ACCESS. These buffers are re-uploaded on the copy queue next time this flight
// slot comes round, so they must end the gfx frame in a copy-compatible state.
world_render_end :: proc(world: ^World, frame_slot: u64) {
    dx.buffer_transition(renderer_dx.cmd_gfx, &world.render.transform[frame_slot].resource,     {}, {.NO_ACCESS})
    dx.buffer_transition(renderer_dx.cmd_gfx, &world.render.mesh_instance[frame_slot].resource, {}, {.NO_ACCESS})
    dx.buffer_transition(renderer_dx.cmd_gfx, &world.render.lights[frame_slot].resource,        {}, {.NO_ACCESS})
}

// gfx: shared asset buffers + textures → readable. Once per frame, regardless of world/view count.
asset_buffers_begin :: proc() {
    dx.buffer_transition(renderer_dx.cmd_gfx, &asset_buffers.mesh_buffer.resource,      {.ALL_SHADING}, {.SHADER_RESOURCE})
    dx.buffer_transition(renderer_dx.cmd_gfx, &asset_buffers.material_buffer.resource,  {.ALL_SHADING}, {.SHADER_RESOURCE})
    dx.buffer_transition(renderer_dx.cmd_gfx, &asset_buffers.position_buffer.resource,  {.ALL_SHADING}, {.SHADER_RESOURCE})
    dx.buffer_transition(renderer_dx.cmd_gfx, &asset_buffers.attribute_buffer.resource, {.ALL_SHADING}, {.SHADER_RESOURCE})
    dx.buffer_transition(renderer_dx.cmd_gfx, &asset_buffers.index_buffer.resource,     {.INDEX_INPUT}, {.INDEX_BUFFER})
    for &tex in asset_buffers.texture_buffers {
        dx.texture_transition(renderer_dx.cmd_gfx, &tex.resource, {.PIXEL_SHADING}, {.SHADER_RESOURCE}, .SHADER_RESOURCE)
    }
}

// ============================ Resource helpers ============================

@(private="file")
buffers_resource_create :: proc(element_size: u32, num_elements: u32, heap: ^dx.Descriptor_Heap) -> Resource_With_Upload {
    // D3D12 rejects a 0-byte resource; keep at least one element so an empty scene
    // (no instances/meshes) doesn't crash resource creation.
    count := max(num_elements, 1)
    r: Resource_With_Upload
    r.resource      = dx.buffer_create(renderer_dx.render_context, {element_size = element_size, num_elements = count, heap_type = .DEFAULT})
    r.resource_view = dx.descriptor_heap_register_srv(renderer_dx.render_context, heap, r.resource)
    r.upload        = dx.buffer_create(renderer_dx.render_context, {element_size = element_size, num_elements = count, heap_type = .UPLOAD})
    r.upload_ptr    = dx.buffer_map(r.upload)
    return r
}

@(private="file")
buffers_resource_destroy :: proc(r: Resource_With_Upload) {
    dx.buffer_unmap(r.upload)
    dx.buffer_destroy(r.upload)
    dx.buffer_destroy(r.resource)
}

@(private="file")
buffers_texture_create :: proc(width: u32, height: u32, format: dxgi.FORMAT) -> Resource_With_Upload {
    r: Resource_With_Upload
    r.resource = dx.texture2d_create(renderer_dx.render_context,
        {width = width, height = height, format = format, mip_levels = 1, heap_type = .DEFAULT})
    r.resource_view = dx.descriptor_heap_register_srv(renderer_dx.render_context, &renderer_dx.resource_heap, r.resource)

    row_size := (int(width) * 4 + 255) &~ 255
    r.upload = dx.buffer_create(renderer_dx.render_context, {
        element_size = 1,
        num_elements = u32(row_size * int(height)), heap_type = .UPLOAD})
    r.upload_ptr = dx.buffer_map(r.upload)
    return r
}

@(private="file")
buffers_texture_copy :: proc(cmd: dx.Command_List, target: ^Resource_With_Upload, source: Image) {
    src_row_size := source.width * 4
    dst_row_size := (src_row_size + 255) &~ 255
    for y in 0..<source.height {
        ptr := uintptr(target.upload_ptr) + uintptr(y * dst_row_size)
        mem.copy(rawptr(ptr), raw_data(source.pixels[y * src_row_size:]), int(src_row_size))
    }

    dx.texture_transition(cmd, &target.resource, {.COPY}, {.COPY_DEST}, .COMMON)

    dst := d3d12.TEXTURE_COPY_LOCATION{ pResource = target.resource.handle, Type = .SUBRESOURCE_INDEX }
    dst.SubresourceIndex = 0
    src := d3d12.TEXTURE_COPY_LOCATION{ pResource = target.upload.handle, Type = .PLACED_FOOTPRINT }
    src.PlacedFootprint = {Offset = 0, Footprint = {
        Format = dx_format(source.format), Width = u32(source.width), Height = u32(source.height), Depth = 1, RowPitch = u32(dst_row_size),
    }}
    cmd.handle->CopyTextureRegion(&dst, 0, 0, 0, &src, nil)

    dx.texture_transition(cmd, &target.resource, {}, {.NO_ACCESS}, .COMMON)
}

@(private="file")
dx_format :: proc(format: Image_Format) -> dxgi.FORMAT {
    switch format {
        case .RGBA8: return .R8G8B8A8_UNORM
        case .RGBA8_SRGB: return .R8G8B8A8_UNORM_SRGB
    }
    return .UNKNOWN
}
