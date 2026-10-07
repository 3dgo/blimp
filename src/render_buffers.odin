package blimp

import "core:log"
import "core:mem"
import "core:hash"
import "core:math"
import "core:math/linalg"
import "core:slice"
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
// copies are driven from renderer_dx_draw_frame using the primitives here, right next to the
// transitions they depend on. The one exception is asset_buffers_upload, the shared asset copy (at init
// and after an asset hot reload), with no per-frame barrier pairing, which is cohesive enough to own outright.

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
    skin_buffer: Resource_With_Upload,   // Skin_Vertex per skinned vertex (Mesh.skin_offset)

    material_buffer: Resource_With_Upload,
    material_buffer_data: [dynamic]Material,

    texture_buffers: [dynamic]Resource_With_Upload,
    texture_ui:      [dynamic]dx.Resource_View,   // each texture's SRV in the ImGui heap (Resources window tooltip)
    sampler:       dx.Resource_View,   // linear: render mode .Clean
    sampler_point: dx.Resource_View,   // point: the retro look's point sampling
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

    bones: [FRAMES_IN_FLIGHT]Resource_With_Upload,   // animated entities' skin matrices (world_anim.odin), Mesh_Instance_Data.bone_offset into it
    bone_data: [dynamic]mat4,

    // The world's baked probe grid (World.probes), one copy: it only changes on a bake or load, which wait
    // for the GPU first (world_render_probes_recreate). No handle when not baked.
    probes:        Resource_With_Upload,
    probe_depth:   Resource_With_Upload,    // World.probes.depth, one Probe_Depth per probe
    probe_atlas:    Resource_With_Upload,   // World.probes.atlas as a texture, for ImGui (Bake and Resources windows)
    probe_atlas_ui: dx.Resource_View,       // its SRV in the ImGui heap
    probes_upload: bool,   // stage both on the copy queue next frame

    draw_cmd:     [FRAMES_IN_FLIGHT]dx.Resource,
    draw_cmd_ptr: [FRAMES_IN_FLIGHT]rawptr,
    draw_cmd_data: [dynamic]d3d12.DRAW_INDEXED_ARGUMENTS,   // grouped by blend, in EntityBlend order
    draw_first:    [EntityBlend]u32,   // each blend's range of draw_cmd_data: its own PSO, one ExecuteIndirect
    draw_count:    [EntityBlend]u32,

    // Shadow maps (render_shadows.odin). One map: it's drawn and read within a frame on the gfx queue, so
    // flights never overlap on it. The slice cameras are per flight, written in place like draw_cmd.
    shadow_map:       dx.Resource,   // MAX_SHADOW_SLICES × SHADOW_MAP_SIZE² R32_TYPELESS array
    shadow_map_srv:   dx.Resource_View,
    shadow_dsv_heap:  dx.Descriptor_Heap,
    shadow_dsv:       [MAX_SHADOW_SLICES]dx.Resource_View,
    shadow_views:     [FRAMES_IN_FLIGHT]dx.Resource,   // Shadow_View per slice (UPLOAD)
    shadow_views_ptr: [FRAMES_IN_FLIGHT]rawptr,
    shadow_views_srv: [FRAMES_IN_FLIGHT]dx.Resource_View,
    shadow_slices:    [dynamic]Shadow_Slice,   // this frame's slices in use, rebuilt by buffers_build_scene
    // Static shadow caching (render_shadows_draw): a slice is redrawn only when its camera changed or
    // something that casts changed since it was last drawn. Slices keep their depth between frames.
    shadow_casters:       u64,   // hash of everything that casts this frame (transform + mesh per instance)
    shadow_casters_drawn: u64,   // the hash the slices were last drawn with
    shadow_drawn:         [MAX_SHADOW_SLICES]Maybe(mat4),   // the camera each slice holds depth for; nil = must draw
    shadow_missed, shadow_missed_logged: int,   // shadowed lights that got no slices this frame / when last logged
}

// One entity-mesh pair. The shader indexes it (via SV_StartInstanceLocation) to reach the
// entity's transform and the mesh's material. Mirrors the MeshInstance struct in the shader.
Mesh_Instance_Data :: struct {
    transform: u32,
    mesh: u32,
    material: u32,
    shading: u32,   // u32(ShadingModel): SHADING_* in shading.slang
    tint: vec4,     // entity_tint, alpha 1: multiplies the albedo
    bone_offset: u32,   // its entity's skin matrices in World_Render.bones; NO_BONES = draw the mesh as stored (rest pose)
    _pad: [3]u32,
}
#assert(size_of(Mesh_Instance_Data) == 48)

NO_BONES :: max(u32)

// One light entity, rebuilt each frame. Mirrors the Light struct in the shader.
GPU_Light :: struct {
    position: vec3, type: u32,         // u32(EntityLightType)
    direction: vec3, radius: f32,      // entity +Z (also the cylinder's axis); range.y, where the falloff reaches zero
    color: vec3, cos_outer: f32,       // linear colour; cos(fov / 2) (spot)
    intensity: f32, cos_inner: f32,    // cos(inner_fov / 2) (spot)
    inner_radius: f32, falloff: u32,   // range.x; u32(EntityLightFalloff)
    beam_radius: f32, beam_inner: f32, // radius, inner_radius (cylinder)
    shadow_slice: u32,                 // first shadow map slice (render_shadows.odin), SHADOW_NONE = unshadowed
    shadow_texel: f32,                 // world size of a shadow texel (at 1 unit for spot / point): the receiver's normal offset
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

// Creates the shared, static, asset-derived buffers: at init, and again after an asset hot reload
// (asset_system_reload). asset_buffers_upload fills them.
asset_buffers_create :: proc() {
    asset_buffers.mesh_buffer      = buffers_resource_create(size_of(Mesh), u32(len(asset_system.meshes)), &renderer_dx.resource_heap)
    asset_buffers.index_buffer     = buffers_resource_create(size_of(u32), u32(len(asset_system.vertex_indices)), &renderer_dx.resource_heap)
    asset_buffers.position_buffer  = buffers_resource_create(size_of(vec3), u32(len(asset_system.vertex_positions)), &renderer_dx.resource_heap)
    asset_buffers.attribute_buffer = buffers_resource_create(size_of(Vertex_Attributes), u32(len(asset_system.vertex_attributes)), &renderer_dx.resource_heap)
    asset_buffers.skin_buffer      = buffers_resource_create(size_of(Skin_Vertex), u32(len(asset_system.vertex_skins)), &renderer_dx.resource_heap)

    for img in asset_system.images {
        tex := buffers_texture_create(img.width, img.height, dx_format(img.format))
        append(&asset_buffers.texture_buffers, tex)
        append(&asset_buffers.texture_ui, dx.descriptor_heap_register_srv(renderer_dx.render_context, &renderer_dx.ui_heap, tex.resource))
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
}

// The samplers materials use. Not asset data, so they live from init to shutdown, across reloads.
asset_samplers_create :: proc() {
    asset_buffers.sampler =dx.descriptor_heap_register_sampler(renderer_dx.render_context, &renderer_dx.sampler_heap, {
        Filter = .MIN_MAG_MIP_LINEAR,
        AddressU = .WRAP, AddressV = .WRAP, AddressW = .WRAP,
        ComparisonFunc = .NEVER, MaxLOD = max(f32),
    })
    asset_buffers.sampler_point = dx.descriptor_heap_register_sampler(renderer_dx.render_context, &renderer_dx.sampler_heap, {
        Filter = .MIN_MAG_MIP_POINT,
        AddressU = .WRAP, AddressV = .WRAP, AddressW = .WRAP,
        ComparisonFunc = .NEVER, MaxLOD = max(f32),
    })
}

asset_samplers_destroy :: proc() {
    dx.descriptor_heap_free(&renderer_dx.sampler_heap, asset_buffers.sampler.heap_slot)
    dx.descriptor_heap_free(&renderer_dx.sampler_heap, asset_buffers.sampler_point.heap_slot)
}

// Frees the asset buffers and hands their bindless slots back. The GPU must be idle.
asset_buffers_destroy :: proc() {
    for tex in asset_buffers.texture_buffers {
        dx.descriptor_heap_free(&renderer_dx.resource_heap, tex.resource_view.heap_slot)
        buffers_resource_destroy(tex)
    }
    delete(asset_buffers.texture_buffers)
    asset_buffers.texture_buffers = nil
    for view in asset_buffers.texture_ui do dx.descriptor_heap_free(&renderer_dx.ui_heap, view.heap_slot)
    delete(asset_buffers.texture_ui)
    asset_buffers.texture_ui = nil

    for b in ([?]Resource_With_Upload{asset_buffers.material_buffer, asset_buffers.skin_buffer, asset_buffers.attribute_buffer, asset_buffers.position_buffer, asset_buffers.index_buffer, asset_buffers.mesh_buffer}) {
        dx.descriptor_heap_free(&renderer_dx.resource_heap, b.resource_view.heap_slot)
        buffers_resource_destroy(b)
    }
    delete(asset_buffers.material_buffer_data)
    asset_buffers.material_buffer_data = nil
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
    r.bone_data          = make([dynamic]mat4, 0, MAX_BONES, app.allocators.perm)

    for i in 0..<FRAMES_IN_FLIGHT {
        r.draw_cmd[i]     = dx.buffer_create(renderer_dx.render_context, {element_size = size_of(d3d12.DRAW_INDEXED_ARGUMENTS), num_elements = MAX_MESH_INSTANCES, heap_type = .UPLOAD})
        r.draw_cmd_ptr[i] = dx.buffer_map(r.draw_cmd[i])

        r.transform[i]     = buffers_resource_create(size_of(mat4), MAX_MESH_INSTANCES, &renderer_dx.resource_heap)
        r.mesh_instance[i] = buffers_resource_create(size_of(Mesh_Instance_Data), MAX_MESH_INSTANCES, &renderer_dx.resource_heap)
        r.lights[i]        = buffers_resource_create(size_of(GPU_Light), MAX_LIGHTS, &renderer_dx.resource_heap)
        r.bones[i]         = buffers_resource_create(size_of(mat4), MAX_BONES, &renderer_dx.resource_heap)
    }
    world_render_probes_create(world)
    world_shadows_create(world)
}

world_render_destroy :: proc(world: ^World) {
    r := &world.render
    for i in 0..<FRAMES_IN_FLIGHT {
        // Worlds open and close at runtime now, so hand their bindless slots back to the heap.
        dx.descriptor_heap_free(&renderer_dx.resource_heap, r.transform[i].resource_view.heap_slot)
        dx.descriptor_heap_free(&renderer_dx.resource_heap, r.mesh_instance[i].resource_view.heap_slot)
        dx.descriptor_heap_free(&renderer_dx.resource_heap, r.lights[i].resource_view.heap_slot)
        dx.descriptor_heap_free(&renderer_dx.resource_heap, r.bones[i].resource_view.heap_slot)
        buffers_resource_destroy(r.transform[i])
        buffers_resource_destroy(r.mesh_instance[i])
        buffers_resource_destroy(r.lights[i])
        buffers_resource_destroy(r.bones[i])
        dx.buffer_unmap(r.draw_cmd[i])
        dx.buffer_destroy(r.draw_cmd[i])
    }
    delete(r.draw_cmd_data)
    delete(r.transform_data)
    delete(r.mesh_instance_data)
    world_render_probes_destroy(world)
    world_shadows_destroy(world)
    delete(r.lights_data)
    delete(r.bone_data)
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
    clear(&r.bone_data)
    clear(&r.shadow_slices)
    r.shadow_missed = 0
    defer light_shadow_report(r)
    casters := u64(0xcbf29ce484222325)   // FNV-1a offset basis: what casts shadows this frame (shadow caching, render_shadows_draw)
    // Opaque draws go straight into draw_cmd_data; the other blends gather here and follow it in
    // EntityBlend order once every entity is in (deferred, so the MAX_MESH_INSTANCES return does it too).
    // Alpha draws back to front from sort_eye (blending isn't order-independent); Additive is, and stays in
    // entity order.
    later: [EntityBlend][dynamic]d3d12.DRAW_INDEXED_ARGUMENTS
    for &d in later do d = make([dynamic]d3d12.DRAW_INDEXED_ARGUMENTS, context.temp_allocator)
    alpha_depth := make([dynamic]f32, context.temp_allocator)   // per later[.Alpha] command: its distance from sort_eye
    sort_eye := world_sort_eye(world)
    defer {
        r.shadow_casters = casters
        r.draw_count[.Opaque] = u32(len(r.draw_cmd_data))
        alpha_sort(later[.Alpha][:], alpha_depth[:])
        for blend in EntityBlend {
            if blend == .Opaque do continue
            r.draw_first[blend] = u32(len(r.draw_cmd_data))
            r.draw_count[blend] = u32(len(later[blend]))
            append(&r.draw_cmd_data, ..later[blend][:])
        }
    }
    group_scales := light_group_scales(world)   // world_light_groups.odin: power cuts, flicker

    it := hm.iterator_make(&world.entities)
    for entity, handle in hm.iterate(&it) {
        if entity_drawn(entity) && entity.light_type != .None {
            light := entity_gpu_light(entity)
            light.intensity *= group_scales[entity_light_group(entity)]
            if len(r.lights_data) < MAX_LIGHTS {
                if entity.shadow && light.intensity != 0 do light_shadow_assign(r, entity, &light)   // a switched-off light draws no map
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
        shading := entity_shading(world, entity)
        tint := entity_tint(entity)
        bone_offset := NO_BONES
        if skin := anim_skin(world, handle); skin != nil && len(r.bone_data) + len(skin) <= MAX_BONES {
            bone_offset = u32(len(r.bone_data))
            append(&r.bone_data, ..skin)
        }

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
                shading = u32(shading),
                tint = {tint.r, tint.g, tint.b, 1},
                bone_offset = bone_offset,
            })
            if !drawn do continue
            cmd := d3d12.DRAW_INDEXED_ARGUMENTS {
                IndexCountPerInstance = mesh.index_count,
                InstanceCount = 1,
                StartIndexLocation = mesh.index_offset,
                BaseVertexLocation = 0,
                StartInstanceLocation = instance_idx,
            }
            switch entity.blend {
            case .Opaque:   append(&r.draw_cmd_data, cmd)
            case .Alpha:
                append(&later[.Alpha], cmd)
                append(&alpha_depth, linalg.length(mesh_world_center(mesh_idx, r.transform_data[transform_idx]) - sort_eye))
            case .Cutout, .Additive: append(&later[entity.blend], cmd)
            }
            if entity.blend == .Opaque || entity.blend == .Cutout {   // the casters (render_shadows_draw)
                m := r.transform_data[transform_idx]
                casters = hash.fnv64a(mem.ptr_to_bytes(&m), casters)
                id := mesh_idx
                casters = hash.fnv64a(mem.ptr_to_bytes(&id), casters)
                if bone_offset != NO_BONES {   // a pose change is a caster change
                    bones := r.bone_data[bone_offset:]
                    casters = hash.fnv64a(([^]byte)(raw_data(bones))[:len(bones) * size_of(mat4)], casters)
                }
            }
        }
    }
}

// Where Alpha draws are sorted from: the eye of the first view showing `world` (its camera entity's in game
// mode). Views share the world's draw commands, so other views of the same world get that view's order.
@(private="file")
world_sort_eye :: proc(world: ^World) -> vec3 {
    for v in views do if v.world == world {
        if e, ok := render_view_camera_entity(v); ok do return e.position
        return camera_eye(v.camera)
    }
    return {}
}

// The world-space centre of mesh `mesh_idx`'s bounds (its BVH root box) under transform `m`.
@(private="file")
mesh_world_center :: proc(mesh_idx: u32, m: mat4) -> vec3 {
    bvh := &asset_system.mesh_bvhs[mesh_idx]
    if len(bvh.nodes) == 0 do return transform_point(m, {})
    return transform_point(m, (bvh.nodes[0].min + bvh.nodes[0].max) * 0.5)
}

// Sorts `cmds` far to near by `depth` (same length), in place.
@(private="file")
alpha_sort :: proc(cmds: []d3d12.DRAW_INDEXED_ARGUMENTS, depth: []f32) {
    Item :: struct { depth: f32, cmd: d3d12.DRAW_INDEXED_ARGUMENTS }
    items := make([]Item, len(cmds), context.temp_allocator)
    for c, i in cmds do items[i] = {depth[i], c}
    slice.sort_by(items, proc(a, b: Item) -> bool { return a.depth > b.depth })
    for it, i in items do cmds[i] = it.cmd
}

// A light entity as the shader sees it. The baker (editor_bake.odin) lights with the same values.
entity_gpu_light :: proc(entity: ^Entity) -> GPU_Light {
    light := GPU_Light {
        position = entity.position,
        type = u32(entity.light_type),
        direction = entity_forward(entity),
        color = entity.color,
        intensity = entity.intensity,
        shadow_slice = SHADOW_NONE,   // buffers_build_scene hands out slices
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
    return light
}

// ============================ Uploads ============================

// Uploads the asset buffers through the copy queue and waits for it, on a command list of its own so it
// works between frames as well as at init. The entity buffers are staged per frame from
// renderer_dx_draw_frame instead.
asset_buffers_upload :: proc() {
    alloc := dx.command_allocator_create(renderer_dx.render_context, {type = .COPY})
    cmd   := dx.command_list_create(renderer_dx.render_context, alloc, {type = .COPY})
    fence := dx.fence_create(renderer_dx.render_context, 0)
    buffers_upload_static(cmd)
    dx.command_list_close(cmd)
    dx.command_list_execute(renderer_dx.cmd_queue_copy, {cmd})
    dx.command_queue_signal(renderer_dx.cmd_queue_copy, fence, 1)
    dx.fence_wait(fence, 1)
    dx.fence_destroy(fence)
    dx.command_list_destroy(cmd)
    dx.command_allocator_destroy(alloc)
}

@(private="file")
buffers_upload_static :: proc(cmd: dx.Command_List) {
    buffers_resource_copy(cmd, &asset_buffers.mesh_buffer,      asset_system.meshes[:])
    buffers_resource_copy(cmd, &asset_buffers.index_buffer,     asset_system.vertex_indices[:])
    buffers_resource_copy(cmd, &asset_buffers.position_buffer,  asset_system.vertex_positions[:])
    buffers_resource_copy(cmd, &asset_buffers.attribute_buffer, asset_system.vertex_attributes[:])
    buffers_resource_copy(cmd, &asset_buffers.skin_buffer,      asset_system.vertex_skins[:])
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
// renderer_dx_draw_frame decides *when* these run; they group the uploads and barriers by owner so a
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
    buffers_resource_copy(renderer_dx.cmd_copy, &r.bones[frame_slot],         r.bone_data[:])
    mem.copy(r.draw_cmd_ptr[frame_slot], raw_data(r.draw_cmd_data), size_of(d3d12.DRAW_INDEXED_ARGUMENTS) * len(r.draw_cmd_data))
    world_shadows_upload(world, frame_slot)
    if r.probes_upload {
        buffers_resource_copy(renderer_dx.cmd_copy, &r.probes, world.probes.probes)
        if len(world.probes.depth) > 0 do buffers_resource_copy(renderer_dx.cmd_copy, &r.probe_depth, world.probes.depth)
        if r.probe_atlas.resource.handle != nil do buffers_texture_copy(renderer_dx.cmd_copy, &r.probe_atlas, world.probes.atlas)
        r.probes_upload = false
    }
}

// gfx: the world's freshly staged buffers → shader-readable for this frame's scene passes.
world_render_begin :: proc(world: ^World, frame_slot: u64) {
    dx.buffer_transition(renderer_dx.cmd_gfx, &world.render.mesh_instance[frame_slot].resource, {.ALL_SHADING}, {.SHADER_RESOURCE})
    dx.buffer_transition(renderer_dx.cmd_gfx, &world.render.transform[frame_slot].resource,     {.ALL_SHADING}, {.SHADER_RESOURCE})
    dx.buffer_transition(renderer_dx.cmd_gfx, &world.render.lights[frame_slot].resource,        {.ALL_SHADING}, {.SHADER_RESOURCE})
    dx.buffer_transition(renderer_dx.cmd_gfx, &world.render.bones[frame_slot].resource,         {.ALL_SHADING}, {.SHADER_RESOURCE})
    if world.render.probes.resource.handle != nil {
        dx.buffer_transition(renderer_dx.cmd_gfx, &world.render.probes.resource,      {.ALL_SHADING}, {.SHADER_RESOURCE})
        dx.buffer_transition(renderer_dx.cmd_gfx, &world.render.probe_depth.resource, {.ALL_SHADING}, {.SHADER_RESOURCE})
    }
    // Copied once per bake, so (like asset textures) it stays readable rather than going back to NO_ACCESS.
    if world.render.probe_atlas.resource.handle != nil do dx.texture_transition(renderer_dx.cmd_gfx, &world.render.probe_atlas.resource, {.PIXEL_SHADING}, {.SHADER_RESOURCE}, .SHADER_RESOURCE)
}

// gfx: back to NO_ACCESS. These buffers are re-uploaded on the copy queue next time this flight
// slot comes round, so they must end the gfx frame in a copy-compatible state.
world_render_end :: proc(world: ^World, frame_slot: u64) {
    dx.buffer_transition(renderer_dx.cmd_gfx, &world.render.transform[frame_slot].resource,     {}, {.NO_ACCESS})
    dx.buffer_transition(renderer_dx.cmd_gfx, &world.render.mesh_instance[frame_slot].resource, {}, {.NO_ACCESS})
    dx.buffer_transition(renderer_dx.cmd_gfx, &world.render.lights[frame_slot].resource,        {}, {.NO_ACCESS})
    dx.buffer_transition(renderer_dx.cmd_gfx, &world.render.bones[frame_slot].resource,         {}, {.NO_ACCESS})
    if world.render.probes.resource.handle != nil {
        dx.buffer_transition(renderer_dx.cmd_gfx, &world.render.probes.resource,      {}, {.NO_ACCESS})
        dx.buffer_transition(renderer_dx.cmd_gfx, &world.render.probe_depth.resource, {}, {.NO_ACCESS})
    }
}

// gfx: shared asset buffers + textures → readable. Once per frame, regardless of world/view count.
asset_buffers_begin :: proc() {
    dx.buffer_transition(renderer_dx.cmd_gfx, &asset_buffers.mesh_buffer.resource,      {.ALL_SHADING}, {.SHADER_RESOURCE})
    dx.buffer_transition(renderer_dx.cmd_gfx, &asset_buffers.material_buffer.resource,  {.ALL_SHADING}, {.SHADER_RESOURCE})
    dx.buffer_transition(renderer_dx.cmd_gfx, &asset_buffers.position_buffer.resource,  {.ALL_SHADING}, {.SHADER_RESOURCE})
    dx.buffer_transition(renderer_dx.cmd_gfx, &asset_buffers.attribute_buffer.resource, {.ALL_SHADING}, {.SHADER_RESOURCE})
    dx.buffer_transition(renderer_dx.cmd_gfx, &asset_buffers.skin_buffer.resource,      {.ALL_SHADING}, {.SHADER_RESOURCE})
    dx.buffer_transition(renderer_dx.cmd_gfx, &asset_buffers.index_buffer.resource,     {.INDEX_INPUT}, {.INDEX_BUFFER})
    for &tex in asset_buffers.texture_buffers {
        dx.texture_transition(renderer_dx.cmd_gfx, &tex.resource, {.PIXEL_SHADING}, {.SHADER_RESOURCE}, .SHADER_RESOURCE)
    }
}

// ============================ Resource helpers ============================

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

buffers_resource_destroy :: proc(r: Resource_With_Upload) {
    dx.buffer_unmap(r.upload)
    dx.buffer_destroy(r.upload)
    dx.buffer_destroy(r.resource)
}

// Binds the shared index buffer (every mesh's indices) for indexed draws.
asset_buffers_bind_indices :: proc(cmd: dx.Command_List) {
    cmd.handle->IASetIndexBuffer(&d3d12.INDEX_BUFFER_VIEW{
        BufferLocation = dx.resource_get_gpu_address(asset_buffers.index_buffer.resource),
        SizeInBytes    = u32(len(asset_system.vertex_indices) * size_of(u32)),
        Format         = .R32_UINT,
    })
}

// Bytes per row of an RGBA8 texture's upload copy: D3D12 wants rows 256-byte aligned.
texture_row_pitch :: proc(width: u32) -> u32 {
    return (width * 4 + 255) &~ 255
}

buffers_texture_create :: proc(width: u32, height: u32, format: dxgi.FORMAT) -> Resource_With_Upload {
    r: Resource_With_Upload
    r.resource = dx.texture2d_create(renderer_dx.render_context,
        {width = width, height = height, format = format, mip_levels = 1, heap_type = .DEFAULT})
    r.resource_view = dx.descriptor_heap_register_srv(renderer_dx.render_context, &renderer_dx.resource_heap, r.resource)

    r.upload = dx.buffer_create(renderer_dx.render_context, {
        element_size = 1,
        num_elements = texture_row_pitch(width) * height, heap_type = .UPLOAD})
    r.upload_ptr = dx.buffer_map(r.upload)
    return r
}

@(private="file")
buffers_texture_copy :: proc(cmd: dx.Command_List, target: ^Resource_With_Upload, source: Image) {
    src_row_size := source.width * 4
    dst_row_size := texture_row_pitch(source.width)
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

dx_format :: proc(format: Image_Format) -> dxgi.FORMAT {
    switch format {
        case .RGBA8: return .R8G8B8A8_UNORM
        case .RGBA8_SRGB: return .R8G8B8A8_UNORM_SRGB
    }
    return .UNKNOWN
}
