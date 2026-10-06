package blimp

import "dx"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "vendor:directx/d3d12"
import im_dx12 "lib:odin-imgui/imgui_impl_dx12"

Renderer_DX :: struct {
    render_context: dx.Render_Context,
    cmd_queue_gfx: dx.Command_Queue,
    cmd_queue_copy: dx.Command_Queue,
    swapchain: dx.Swapchain,

    root_signature: dx.Root_Signature,

    resource_heap: dx.Descriptor_Heap,
    sampler_heap: dx.Descriptor_Heap,
    ui_heap: dx.Descriptor_Heap,

    cmd_alloc_gfx: [FRAMES_IN_FLIGHT]dx.Command_Allocator,
    cmd_alloc_copy: [FRAMES_IN_FLIGHT]dx.Command_Allocator,

    cmd_gfx: dx.Command_List,
    cmd_copy: dx.Command_List,

    indirect_sig: dx.Command_Signature,

    slang_compiler: dx.Slang_Compiler,
    scene: [EntityBlend]Shader_Pipeline,   // scene.slang's vert_main with each blend's fragment entry point

    frame_fence_copy: dx.Fence,
    frame_fence_gfx: dx.Fence,

    frame_val: u64,
    frame: struct {   // the frame being recorded, between renderer_dx_draw_frame and renderer_dx_present
        slot:       u64,   // frame_val % FRAMES_IN_FLIGHT: which per-flight resources it uses
        backbuffer: u32,
        t_frame, t_ui: int,   // open GPU timer scopes
    },

    // Full-window screenshot (remote `screenshot ui`): set ui_shot_requested and the next frame copies the
    // swapchain image after the UI draws; ui_shot_frame (0 = none) is the frame_val to wait for before reading ui_shot.
    ui_shot_requested: bool,
    ui_shot: dx.Texture_Readback,
    ui_shot_frame: u64,
}
renderer_dx: Renderer_DX

Frame_Constants :: struct {
    view_mat: mat4,
    proj_mat: mat4,
    camera_pos: vec3,
    light_count: u32,

    transform_buffer_slot: u32,
    mesh_instance_buffer_slot: u32,
    lights_buffer_slot: u32,

    mesh_buffer_slot: u32,
    position_buffer_slot: u32,
    attribute_buffer_slot: u32,
    material_buffer_slot: u32,
    sampler_slot: u32,

    debug_line_buffer_slot: u32,
    hdr_texture_slot: u32,   // the view's scene target, read by the post pass
    exposure: f32,           // 2^world.settings.exposure
    depth_texture_slot: u32, // the view's scene depth (R32_FLOAT), read by passes at the display size
    scene_scale: u32,        // display pixels per scene pixel, each way (render_view_scene_scale)
    color_levels: f32,       // the post chain quantizes each channel to 0..color_levels (2^bits - 1); 0 = off
    scene_cover: vec2,       // the part of the scene target the display covers: display / (scene_scale * scene size)
    vertex_snap: vec2,       // the scene VS rounds NDC xy to steps of 1 / vertex_snap (half the scene size); 0 = off
    affine: f32,             // 0 = perspective-correct UVs, 1 = affine; in between blends

    // Baked probes (world_probes.odin) of the world's level; probe_dims 0 = not baked (the shader falls back to a flat ambient).
    probe_buffer_slot: u32,
    probe_origin:  vec3,
    probe_spacing: f32,
    probe_dims:    uvec3,
    lighting_view:  u32,   // Lighting_View
    indirect_scale: f32,   // × indirect light (Render_View.indirect_scale)
    probe_layers:   u32,   // layers in the probe buffer (world_probes.odin): static, then one per lit light group
    probe_depth_slot: u32,   // their depth maps (Probe_Depth), for the visibility test
    _pad_layers:    u32,
    probe_layer_scale: [2]vec4,   // each layer's light-group scale this frame, layer k at [k / 4][k % 4]

    // The world's shadow maps (render_shadows.odin): the slice array and its Shadow_View per slice.
    shadow_map_slot:         u32,
    shadow_view_buffer_slot: u32,

    // The retro post chain (render_post.odin, post.slang): its scene-size intermediates, and the effects'
    // amounts from Retro_Settings, each 0 when its effect is off (render_view_update_constants).
    signal_texture_slot:    u32,   // the signal: tonemapped, quantized, display-space
    bloom_texture_slot:     u32,   // the bloom blurred across
    bloom_out_texture_slot: u32,   // then down: what the upscale adds
    crt:          u32,   // nonzero: the upscale is a CRT's (else point-sampled)
    dither:       f32,   // Bayer threshold spread, 0..1
    luma_blur:    f32,
    chroma_blur:  f32,
    scanlines:    f32,   // beam profile strength
    beam_dark:    f32,
    beam_bright:  f32,
    mask:         f32,
    bloom:        f32,
    bloom_radius: f32,
    gamma:        f32,
    brightness:   f32,

    // Distance fog (World_Settings.fog), in the signal pass: view distance from the scene depth through
    // inv_proj, faded into fog_color (the background, display space) between fog_start and fog_end.
    fog_color:    vec3,
    fog_start:    f32,
    fog_end:      f32,   // <= fog_start: fog off
    _pad_fog:     [2]f32,
    inv_proj:     mat4,  // the projection this view rendered with, inverted (the camera entity's in game mode)

    skin_buffer_slot: u32,   // Skin_Vertex per skinned vertex (asset)
    bone_buffer_slot: u32,   // the world's skin matrices this frame (World_Render.bones)

    _padding: [512 - 472]byte,   // CBVs come in 256-byte steps
}
#assert(offset_of(Frame_Constants, signal_texture_slot) == 312)
#assert(offset_of(Frame_Constants, _padding) == 472)
#assert(offset_of(Frame_Constants, probe_layer_scale) % 16 == 0)
#assert(MAX_PROBE_LAYERS <= 8)
#assert(size_of(Frame_Constants) == 512)
// HLSL cbuffer packing: a vector may not straddle a 16-byte row (the shader would push it to the
// next row and every later field would read shifted); matrices start on a row. Odin has no layout
// attribute for this, so check each non-scalar field.
#assert(offset_of(Frame_Constants, proj_mat) % 16 == 0)
#assert(offset_of(Frame_Constants, camera_pos) % 16 + size_of(vec3)  <= 16)
#assert(offset_of(Frame_Constants, scene_cover) % 16 + size_of(vec2)  <= 16)
#assert(offset_of(Frame_Constants, vertex_snap) % 16 + size_of(vec2)  <= 16)
#assert(offset_of(Frame_Constants, probe_origin) % 16 + size_of(vec3)  <= 16)
#assert(offset_of(Frame_Constants, probe_dims) % 16 + size_of(uvec3) <= 16)
#assert(offset_of(Frame_Constants, fog_color) % 16 + size_of(vec3)  <= 16)
#assert(offset_of(Frame_Constants, inv_proj) % 16 == 0)

renderer_dx_init :: proc() {
    // --gpu-validation (debug builds): D3D12 GPU-based validation, for a bad descriptor index or resource state.
    renderer_dx.render_context = dx.render_context_create(slice.contains(os.args, "--gpu-validation"))
    when ODIN_DEBUG {
        dx.render_context_register_debug_callback(renderer_dx.render_context, renderer_dx_debug_callback)
    }

    // Root Signature
    root_sig_builder := dx.root_signature_builder_create(app.allocators.perm)
    dx.root_signature_builder_add_cbv(&root_sig_builder, 0, 0, {.DATA_STATIC_WHILE_SET_AT_EXECUTE})
    renderer_dx.root_signature = dx.root_signature_build(renderer_dx.render_context, root_sig_builder)
    dx.root_signature_builder_destroy(root_sig_builder)

    // Descriptor Heaps
    renderer_dx.resource_heap = dx.descriptor_heap_create(renderer_dx.render_context,
        {type = .CBV_SRV_UAV, cap = 10_000, flags = {.SHADER_VISIBLE}}, app.allocators.perm)
    renderer_dx.sampler_heap = dx.descriptor_heap_create(renderer_dx.render_context,
        {type = .SAMPLER, cap = 2048, flags = {.SHADER_VISIBLE}}, app.allocators.perm)
    renderer_dx.ui_heap = dx.descriptor_heap_create(renderer_dx.render_context,
        {type = .CBV_SRV_UAV, cap = 10_000, flags = {.SHADER_VISIBLE}}, app.allocators.perm)

    // Cmd
    renderer_dx.cmd_queue_gfx  = dx.command_queue_create(renderer_dx.render_context, {type = .DIRECT})
    renderer_dx.cmd_queue_copy = dx.command_queue_create(renderer_dx.render_context, {type = .COPY})

    for i in 0..<FRAMES_IN_FLIGHT {
        renderer_dx.cmd_alloc_gfx[i]  = dx.command_allocator_create(renderer_dx.render_context, {type = .DIRECT})
        renderer_dx.cmd_alloc_copy[i] = dx.command_allocator_create(renderer_dx.render_context, {type = .COPY})
    }
    renderer_dx.cmd_gfx  = dx.command_list_create(renderer_dx.render_context, renderer_dx.cmd_alloc_gfx[0],  {type = .DIRECT})
    renderer_dx.cmd_copy = dx.command_list_create(renderer_dx.render_context, renderer_dx.cmd_alloc_copy[0], {type = .COPY})

    renderer_dx.indirect_sig = dx.command_signature_create(renderer_dx.render_context)

    // Fence
    renderer_dx.frame_fence_gfx = dx.fence_create(renderer_dx.render_context, 0)
    renderer_dx.frame_fence_copy = dx.fence_create(renderer_dx.render_context, 0)

    // Swapchain
    renderer_dx.swapchain = dx.swapchain_create(
        renderer_dx.render_context, app.window_hwnd, renderer_dx.cmd_queue_gfx,
        {width = app.window_width, height = app.window_height, format = .R8G8B8A8_UNORM, depth_format = .D32_FLOAT, num_frames = 3},
        app.allocators.perm,
    )

    // Scene pipelines, one per entity blend (drawn in that order, render_view.odin). Blended ones test depth
    // but don't write it, so what's behind them still draws.
    renderer_dx.slang_compiler  = dx.slang_compiler_create("./assets_engine/shaders/", app.allocators.perm)
    for blend in EntityBlend {
        opts := dx.PIPELINE_OPTIONS_DEFAULT
        opts.rtv_format = VIEW_HDR_FORMAT
        frag: string
        switch blend {
        case .Opaque:   frag = "frag_main"
        case .Cutout:   frag = "frag_cutout"
        case .Alpha:    frag = "frag_blend"; opts.blend = .Alpha;    opts.depth_write = false
        case .Additive: frag = "frag_blend"; opts.blend = .Additive; opts.depth_write = false
        }
        renderer_dx.scene[blend] = shader_pipeline_create("scene", "vert_main", frag, opts)
    }
    render_post_init()   // post chain: HDR scene target → display target (render_post.odin)
    render_shadows_init()   // depth-only shadow map pass (render_shadows.odin)

    // Debug line renderer — its own shader, PSO, and per-flight buffers
    debug_draw_init()
    gpu_timer_init()   // per-pass GPU timestamps (render_gpu_timer.odin)

    // Shared asset buffers (geometry, materials, textures). Worlds and their views are created when
    // the user opens them (world_registry.odin); nothing is open at startup.
    asset_samplers_create()
    asset_buffers_create()
    asset_buffers_upload()

    // Finish: the frame loop resets both lists before recording
    dx.command_list_close(renderer_dx.cmd_copy)
    dx.command_list_close(renderer_dx.cmd_gfx)
}

// The frame is three calls, so the app can draw the UI into the backbuffer in between without the
// renderer knowing about the UI (app_run):
//
//   renderer_dx_draw_frame()   worlds' draw data, shadows, every view's scene + post + debug lines, and
//                              the backbuffer cleared and bound — ready for the UI to draw into
//   ui_draw(...)               (the app) ImGui's draw data into the backbuffer
//   renderer_dx_submit()       the UI screenshot, end-of-frame state, submit
//   ui_render_platform_windows (the app) windows dragged out of the main one
//   renderer_dx_present()      present and signal
//
// Debug lines must be in debug_draw before renderer_dx_draw_frame (ui_view_debug_lines does the editor's).
renderer_dx_draw_frame :: proc() {
    f := &renderer_dx.frame

    //=== Frame sync: wait out this slot's in-flight frame, then reset its command recording ===
    renderer_dx.frame_val += 1
    f.slot       = renderer_dx.frame_val % FRAMES_IN_FLIGHT
    f.backbuffer = renderer_dx.swapchain.frame_idx

    if renderer_dx.frame_val >= u64(FRAMES_IN_FLIGHT) {
        dx.fence_wait(renderer_dx.frame_fence_gfx, renderer_dx.frame_val - u64(FRAMES_IN_FLIGHT))
    }
    gpu_timer_frame_begin(f.slot)   // this slot's previous frame is done: publish its timings

    dx.command_allocator_reset(&renderer_dx.cmd_alloc_gfx[f.slot])
    dx.command_list_reset(renderer_dx.cmd_gfx, renderer_dx.cmd_alloc_gfx[f.slot])
    f.t_frame = gpu_timer_begin(renderer_dx.cmd_gfx, "frame")
    dx.command_allocator_reset(&renderer_dx.cmd_alloc_copy[f.slot])
    dx.command_list_reset(renderer_dx.cmd_copy, renderer_dx.cmd_alloc_copy[f.slot])

    //=== Worlds: rebuild each world's draw mirror once and stage it (copy queue) ===
    // Shared by every view of that world. Runtime spawns/removals appear next frame.
    for w in worlds do world_render_upload(w, f.slot)

    //=== Views: per-camera frame constants ===
    for v in views do render_view_update_constants(v, f.slot)

    // Debug lines: each view's range of one shared list, filled before the frame. Uploaded once, drawn per view below.
    debug_draw_upload(f.slot)

    //=== gfx: make scene data shader-readable (per world, then shared assets once) ===
    t_barriers := gpu_timer_begin(renderer_dx.cmd_gfx, "barriers")
    for w in worlds do world_render_begin(w, f.slot)
    asset_buffers_begin()
    gpu_timer_end(renderer_dx.cmd_gfx, t_barriers)

    dx.command_list_close(renderer_dx.cmd_copy)
    dx.command_list_execute(renderer_dx.cmd_queue_copy, {renderer_dx.cmd_copy})
    dx.command_queue_signal(renderer_dx.cmd_queue_copy, renderer_dx.frame_fence_copy, renderer_dx.frame_val)

    dx.command_queue_wait(renderer_dx.cmd_queue_gfx, renderer_dx.frame_fence_copy, renderer_dx.frame_val)

    //=== Shadow maps (one set per world, shared by its views) ===
    t_shadows := gpu_timer_begin(renderer_dx.cmd_gfx, "shadows")
    for w in worlds do render_shadows_draw(w, f.slot)
    gpu_timer_end(renderer_dx.cmd_gfx, t_shadows)

    //=== Scene passes (one per view → its target) ===
    for v in views {
        t_view := gpu_timer_begin(renderer_dx.cmd_gfx, fmt.tprintf("view %d (%s)", v.id, v.world.title))
        render_view_draw(v, f.slot)
        render_post_draw(v)
        debug_draw_lines(renderer_dx.cmd_gfx, v.debug_first, v.debug_count)   // display target + constants still bound: after the post chain, so line colours stay exact
        gpu_timer_end(renderer_dx.cmd_gfx, t_view)
    }
    debug_draw_clear()

    //=== UI pass (gfx → swapchain): the backbuffer, cleared and bound for the app's ui_draw ===
    f.t_ui = gpu_timer_begin(renderer_dx.cmd_gfx, "ui")
    for v in views do render_view_end(v)   // view targets become textures ImGui samples into its windows

    clear_color := [4]f32{0, 0, 0, 1.0}
    dx.texture_transition(renderer_dx.cmd_gfx, &renderer_dx.swapchain.back_buffers[f.backbuffer], {.RENDER_TARGET}, {.RENDER_TARGET}, .RENDER_TARGET)
    renderer_dx.cmd_gfx.handle->OMSetRenderTargets(1, &renderer_dx.swapchain.back_buffer_views[f.backbuffer].cpu_handle, false, nil)
    renderer_dx.cmd_gfx.handle->ClearRenderTargetView(renderer_dx.swapchain.back_buffer_views[f.backbuffer].cpu_handle, &clear_color, 0, nil)
}

// After the UI drew into the backbuffer: closes and submits the frame.
renderer_dx_submit :: proc() {
    f := &renderer_dx.frame
    gpu_timer_end(renderer_dx.cmd_gfx, f.t_ui)
    if renderer_dx.ui_shot_requested {   // the main window as shown: views, overlays and ImGui (not windows dragged out of it)
        renderer_dx.ui_shot_requested = false
        if rb, ok := dx.texture_readback_record(renderer_dx.render_context, renderer_dx.cmd_gfx, &renderer_dx.swapchain.back_buffers[f.backbuffer]); ok {
            renderer_dx.ui_shot, renderer_dx.ui_shot_frame = rb, renderer_dx.frame_val
        }
    }

    dx.texture_transition(renderer_dx.cmd_gfx, &renderer_dx.swapchain.back_buffers[f.backbuffer], {}, {.NO_ACCESS}, .PRESENT)

    //=== End-of-frame state reset ===
    for w in worlds do world_render_end(w, f.slot)

    gpu_timer_end(renderer_dx.cmd_gfx, f.t_frame)
    gpu_timer_frame_resolve(renderer_dx.cmd_gfx)

    dx.command_list_close(renderer_dx.cmd_gfx)
    dx.command_list_execute(renderer_dx.cmd_queue_gfx, {renderer_dx.cmd_gfx})
}

renderer_dx_present :: proc() {
    dx.swapchain_present(&renderer_dx.swapchain)
    dx.command_queue_signal(renderer_dx.cmd_queue_gfx, renderer_dx.frame_fence_gfx, renderer_dx.frame_val)
}

renderer_dx_shutdown :: proc() {   // the GPU is idle (app_shutdown waited)
    debug_draw_shutdown()
    render_post_shutdown()
    render_shadows_shutdown()
    gpu_timer_shutdown()

    for p in renderer_dx.scene do shader_pipeline_destroy(p)
    dx.slang_compiler_destroy(&renderer_dx.slang_compiler)

    dx.swapchain_destroy(&renderer_dx.swapchain)

    dx.fence_destroy(renderer_dx.frame_fence_copy)
    dx.fence_destroy(renderer_dx.frame_fence_gfx)

    asset_buffers_destroy()
    asset_samplers_destroy()

    dx.command_signature_destroy(renderer_dx.indirect_sig)

    dx.command_list_destroy(renderer_dx.cmd_copy)
    dx.command_list_destroy(renderer_dx.cmd_gfx)
    for i in 0..<FRAMES_IN_FLIGHT {
        dx.command_allocator_destroy(renderer_dx.cmd_alloc_copy[i])
        dx.command_allocator_destroy(renderer_dx.cmd_alloc_gfx[i])
    }

    dx.root_signature_destroy(renderer_dx.root_signature)
    dx.descriptor_heap_destroy(renderer_dx.ui_heap)
    dx.descriptor_heap_destroy(renderer_dx.sampler_heap)
    dx.descriptor_heap_destroy(renderer_dx.resource_heap)

    dx.command_queue_destroy(renderer_dx.cmd_queue_copy)
    dx.command_queue_destroy(renderer_dx.cmd_queue_gfx)

    dx.render_context_destroy(renderer_dx.render_context)
}

// A graphics pipeline plus the recipe it was built from, so shader hot reload can rebuild it
// (render_shaders_reload).
Shader_Pipeline :: struct {
    module, vs, ps: string,   // slang module and entry points; ps "" = depth only
    options: dx.Pipeline_Options,
    shader:  dx.Compiled_Shader,
    pso:     dx.Pipeline_State,
}

// Builds a pipeline at init, where a shader that doesn't compile is fatal.
shader_pipeline_create :: proc(module, vs, ps: string, options: dx.Pipeline_Options) -> (p: Shader_Pipeline) {
    p = {module = module, vs = vs, ps = ps, options = options}
    ok: bool
    p.shader, ok = dx.slang_compiler_compile_shader(&renderer_dx.slang_compiler, module, vs, ps)
    if !ok do log.panicf("Shader %v (%v, %v) failed to compile", module, vs, ps)
    p.pso = dx.pipeline_create_graphics_pso(renderer_dx.render_context, renderer_dx.root_signature, p.shader, options)
    return
}

shader_pipeline_destroy :: proc(p: Shader_Pipeline) {
    dx.pipeline_destroy_pso(p.pso)
    dx.slang_compiler_destroy_shader(p.shader)
}

// Every pipeline the renderer draws with: what shader hot reload rebuilds.
renderer_dx_pipelines :: proc() -> []^Shader_Pipeline {
    list := make([dynamic]^Shader_Pipeline, context.temp_allocator)
    for &p in renderer_dx.scene do append(&list, &p)
    append(&list, &render_post.signal, &render_post.bloom_h, &render_post.bloom_v, &render_post.upscale)
    append(&list, &render_shadows.pipeline, &debug_draw.pipeline)
    return list[:]
}

// Recompiles every pipeline's shaders from disk (app_hot_reload.odin). All or nothing: shaders share
// structs through common.slang, so if any fails to compile, its errors are logged and every pipeline
// keeps what it had.
render_shaders_reload :: proc() {
    dx.slang_compiler_new_session(&renderer_dx.slang_compiler)
    pipelines := renderer_dx_pipelines()
    shaders := make([]dx.Compiled_Shader, len(pipelines), context.temp_allocator)
    for p, i in pipelines {
        ok: bool
        shaders[i], ok = dx.slang_compiler_compile_shader(&renderer_dx.slang_compiler, p.module, p.vs, p.ps)
        if !ok {
            for s in shaders[:i] do dx.slang_compiler_destroy_shader(s)
            log.errorf("Shader reload: %v (%v, %v) failed; keeping the previous shaders", p.module, p.vs, p.ps)
            return
        }
    }
    renderer_dx_wait_idle()
    for p, i in pipelines {
        shader_pipeline_destroy(p^)
        p.shader = shaders[i]
        p.pso = dx.pipeline_create_graphics_pso(renderer_dx.render_context, renderer_dx.root_signature, p.shader, p.options)
    }
    log.infof("Shader reload: %v pipelines rebuilt", len(pipelines))
}

// Waits until the GPU has finished every submitted frame: before freeing anything a frame in flight may use.
renderer_dx_wait_idle :: proc() {
    dx.fence_wait(renderer_dx.frame_fence_gfx, renderer_dx.frame_val)
}

renderer_dx_resize_window :: proc(new_size: uvec2) {
    dx.swapchain_resize(renderer_dx.render_context, &renderer_dx.swapchain, new_size.x, new_size.y)
}

renderer_dx_resize_view :: proc(view: ^Render_View, new_size: uvec2) {
    renderer_dx_wait_idle()
    render_view_resize(view, new_size.x, new_size.y)
}

// ====================== Callbacks ================================
renderer_dx_debug_callback :: proc "c" (category: d3d12.MESSAGE_CATEGORY, severity: d3d12.MESSAGE_SEVERITY, ID: d3d12.MESSAGE_ID, description: d3d12.LPCSTR, p_context: rawptr) {
    context = app.g_context
    switch severity {
        case .CORRUPTION: log.panicf("DirectX 12 Corruption [%s]: %s", category, description)
        case .ERROR: log.errorf("DirectX 12 Error [%s]: %s", category, description)
        case .WARNING: log.warnf("DirectX 12 Warning [%s]: %s", category, description)
        case .INFO: log.infof("DirectX 12 Info [%s]: %s", category, description)
        case .MESSAGE: log.infof("DirectX 12 Message [%s]: %s", category, description)
    }
}

renderer_dx_ui_srv_alloc :: proc "c" (info: ^im_dx12.InitInfo, out_cpu_desc_handle: ^d3d12.CPU_DESCRIPTOR_HANDLE, out_gpu_desc_handle: ^d3d12.GPU_DESCRIPTOR_HANDLE) {
    context = app.g_context
    idx := dx.descriptor_heap_alloc(&renderer_dx.ui_heap)
    out_cpu_desc_handle.ptr = dx.descriptor_heap_cpu_handle_at(renderer_dx.ui_heap, idx).ptr
    out_gpu_desc_handle.ptr = dx.descriptor_heap_gpu_handle_at(renderer_dx.ui_heap, idx).ptr
}

renderer_dx_ui_srv_free :: proc "c" (info: ^im_dx12.InitInfo, cpu_desc_handle: d3d12.CPU_DESCRIPTOR_HANDLE, gpu_desc_handle: d3d12.GPU_DESCRIPTOR_HANDLE) {
    context = app.g_context
    cpu_idx := u32(cpu_desc_handle.ptr - renderer_dx.ui_heap.cpu_base.ptr) / renderer_dx.ui_heap.stride
    gpu_idx := u32(gpu_desc_handle.ptr - renderer_dx.ui_heap.gpu_base.ptr) / renderer_dx.ui_heap.stride
    assert(cpu_idx == gpu_idx)
    dx.descriptor_heap_free(&renderer_dx.ui_heap, cpu_idx)
}