package blimp

import "dx"
import "core:fmt"
import "core:log"
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
    compiled_shader: dx.Compiled_Shader,
    pso: dx.Pipeline_State,

    frame_fence_copy: dx.Fence,
    frame_fence_gfx: dx.Fence,

    frame_val: u64,

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
    time: f32,
    resolution: uvec2,

    transform_buffer_slot: u32,
    mesh_instance_buffer_slot: u32,
    lights_buffer_slot: u32,
    
    mesh_buffer_slot: u32,
    index_buffer_slot: u32,
    position_buffer_slot: u32,
    attribute_buffer_slot: u32,
    material_buffer_slot: u32,
    sampler_slot: u32,
    
    debug_line_buffer_slot: u32,
    hdr_texture_slot: u32,   // the view's scene target, read by the tonemap pass
    exposure: f32,           // 2^world.settings.exposure

    _padding: [256 - 4*16*2 - 4 - 4*2 - 4*3 - 4 - 4*11 - 4]byte,
}
#assert(size_of(Frame_Constants) == 256)
// HLSL cbuffer packing: a vector may not straddle a 16-byte row (the shader would push it to the
// next row and every later field would read shifted); matrices start on a row. Odin has no layout
// attribute for this, so check each non-scalar field.
#assert(offset_of(Frame_Constants, proj_mat) % 16 == 0)
#assert(offset_of(Frame_Constants, camera_pos) % 16 + size_of(vec3)  <= 16)
#assert(offset_of(Frame_Constants, resolution) % 16 + size_of(uvec2) <= 16)

renderer_dx_init :: proc() {
    renderer_dx.render_context = dx.render_context_create()
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
    init_fence := dx.fence_create(renderer_dx.render_context, 0)
    renderer_dx.frame_fence_gfx = dx.fence_create(renderer_dx.render_context, 0)
    renderer_dx.frame_fence_copy = dx.fence_create(renderer_dx.render_context, 0)

    // Swapchain
    renderer_dx.swapchain = dx.swapchain_create(
        renderer_dx.render_context, app.window_hwnd, renderer_dx.cmd_queue_gfx,
        {width = app.window_width, height = app.window_height, format = .R8G8B8A8_UNORM, depth_format = .D32_FLOAT, num_frames = 3},
        app.allocators.perm,
    )

    // Scene pipeline (opaque)
    renderer_dx.slang_compiler  = dx.slang_compiler_create("./assets_engine/shaders/", app.allocators.perm)
    renderer_dx.compiled_shader = dx.slang_compiler_compile_shader(renderer_dx.slang_compiler, "triangle", "vert_main", "frag_main")
    
    scene_opts := dx.PIPELINE_OPTIONS_DEFAULT
    scene_opts.rtv_format = VIEW_HDR_FORMAT
    renderer_dx.pso             = dx.pipeline_create_graphics_pso(renderer_dx.render_context, renderer_dx.root_signature, renderer_dx.compiled_shader, scene_opts)
    render_post_init()   // tonemap: HDR scene target → display target (render_post.odin)
    
    // Debug line renderer — its own shader, PSO, and per-flight buffers
    debug_draw_init()
    gpu_timer_init()   // per-pass GPU timestamps (render_gpu_timer.odin)

    // Shared asset buffers (geometry, materials, textures). Worlds and their views are created when
    // the user opens them (world_registry.odin); nothing is open at startup.
    asset_buffers_create()
    buffers_upload_static(renderer_dx.cmd_copy)

    dx.command_list_close(renderer_dx.cmd_copy)
    dx.command_list_execute(renderer_dx.cmd_queue_copy, {renderer_dx.cmd_copy})
    
    dx.command_queue_signal(renderer_dx.cmd_queue_copy, init_fence, 1)

    dx.fence_wait(init_fence, 1)

    // Finish
    dx.fence_destroy(init_fence)
    dx.command_list_close(renderer_dx.cmd_gfx)
}

renderer_dx_update :: proc() {
    //=== Frame sync: wait out this slot's in-flight frame, then reset its command recording ===
    renderer_dx.frame_val += 1
    frame_slot := renderer_dx.frame_val % FRAMES_IN_FLIGHT
    backbuffer_idx := renderer_dx.swapchain.frame_idx

    if renderer_dx.frame_val >= u64(FRAMES_IN_FLIGHT) {
        dx.fence_wait(renderer_dx.frame_fence_gfx, renderer_dx.frame_val - u64(FRAMES_IN_FLIGHT))
    }
    gpu_timer_frame_begin(frame_slot)   // this slot's previous frame is done: publish its timings

    dx.command_allocator_reset(&renderer_dx.cmd_alloc_gfx[frame_slot])
    dx.command_list_reset(renderer_dx.cmd_gfx, renderer_dx.cmd_alloc_gfx[frame_slot])
    t_frame := gpu_timer_begin(renderer_dx.cmd_gfx, "frame")
    dx.command_allocator_reset(&renderer_dx.cmd_alloc_copy[frame_slot])
    dx.command_list_reset(renderer_dx.cmd_copy, renderer_dx.cmd_alloc_copy[frame_slot])

    //=== Worlds: rebuild each world's draw mirror once and stage it (copy queue) ===
    // Shared by every view of that world. Runtime spawns/removals appear next frame.
    for w in worlds do world_render_upload(w, frame_slot)

    //=== Views: per-camera frame constants ===
    for v in views do render_view_update_constants(v, frame_slot)

    // Debug lines: each view's editor overlay (origin axes, pick ray/hit, selection box) as its own
    // range of one shared list. Uploaded once, drawn per view below.
    for v in views do pick_view_debug_lines(v)
    debug_draw_upload(frame_slot)

    //=== gfx: make scene data shader-readable (per world, then shared assets once) ===
    t_barriers := gpu_timer_begin(renderer_dx.cmd_gfx, "barriers")
    for w in worlds do world_render_begin(w, frame_slot)
    asset_buffers_begin()
    gpu_timer_end(renderer_dx.cmd_gfx, t_barriers)

    dx.command_list_close(renderer_dx.cmd_copy)
    dx.command_list_execute(renderer_dx.cmd_queue_copy, {renderer_dx.cmd_copy})
    dx.command_queue_signal(renderer_dx.cmd_queue_copy, renderer_dx.frame_fence_copy, renderer_dx.frame_val)
    
    dx.command_queue_wait(renderer_dx.cmd_queue_gfx, renderer_dx.frame_fence_copy, renderer_dx.frame_val)
    
    //=== Scene passes (one per view → its target) ===
    for v in views {
        t_view := gpu_timer_begin(renderer_dx.cmd_gfx, fmt.tprintf("view %d (%s)", v.id, v.world.title))
        render_view_draw(v, frame_slot)
        render_post_draw(v)
        debug_draw_lines(renderer_dx.cmd_gfx, v.debug_first, v.debug_count)   // display target, depth + constants still bound: after the tonemap, so line colours stay exact
        gpu_timer_end(renderer_dx.cmd_gfx, t_view)
    }
    debug_draw_clear()

    //=== UI pass (gfx → swapchain) ===
    t_ui := gpu_timer_begin(renderer_dx.cmd_gfx, "ui")
    for v in views do render_view_end(v)   // view targets become textures ImGui samples into its windows

    clear_color := [4]f32{0, 0, 0, 1.0}
    
    dx.texture_transition(renderer_dx.cmd_gfx, &renderer_dx.swapchain.back_buffers[backbuffer_idx], {.RENDER_TARGET}, {.RENDER_TARGET}, .RENDER_TARGET)
    renderer_dx.cmd_gfx.handle->OMSetRenderTargets(1, &renderer_dx.swapchain.back_buffer_views[backbuffer_idx].cpu_handle, false, nil)
    renderer_dx.cmd_gfx.handle->ClearRenderTargetView(renderer_dx.swapchain.back_buffer_views[backbuffer_idx].cpu_handle, &clear_color, 0, nil)
    ui_draw()
    gpu_timer_end(renderer_dx.cmd_gfx, t_ui)
    if renderer_dx.ui_shot_requested {   // the main window as shown: views, overlays and ImGui (not windows dragged out of it)
        renderer_dx.ui_shot_requested = false
        if rb, ok := dx.texture_readback_record(renderer_dx.render_context, renderer_dx.cmd_gfx, &renderer_dx.swapchain.back_buffers[backbuffer_idx]); ok {
            renderer_dx.ui_shot, renderer_dx.ui_shot_frame = rb, renderer_dx.frame_val
        }
    }

    dx.texture_transition(renderer_dx.cmd_gfx, &renderer_dx.swapchain.back_buffers[backbuffer_idx], {}, {.NO_ACCESS}, .PRESENT)
    
    //=== End-of-frame state reset ===
    for w in worlds do world_render_end(w, frame_slot)

    gpu_timer_end(renderer_dx.cmd_gfx, t_frame)
    gpu_timer_frame_resolve(renderer_dx.cmd_gfx)

    //=== Submit & present ===
    dx.command_list_close(renderer_dx.cmd_gfx)
    dx.command_list_execute(renderer_dx.cmd_queue_gfx, {renderer_dx.cmd_gfx})

    ui_render_platform_windows()
    
    dx.swapchain_present(&renderer_dx.swapchain)

    dx.command_queue_signal(renderer_dx.cmd_queue_gfx, renderer_dx.frame_fence_gfx, renderer_dx.frame_val)
}

renderer_dx_shutdown :: proc() {
    dx.fence_wait(renderer_dx.frame_fence_gfx, renderer_dx.frame_val)

    debug_draw_shutdown()
    render_post_shutdown()
    gpu_timer_shutdown()

    dx.pipeline_destroy_pso(renderer_dx.pso)
    dx.slang_compiler_destroy_shader(renderer_dx.compiled_shader)
    dx.slang_compiler_destroy(renderer_dx.slang_compiler)

    dx.swapchain_destroy(&renderer_dx.swapchain)

    dx.fence_destroy(renderer_dx.frame_fence_copy)
    dx.fence_destroy(renderer_dx.frame_fence_gfx)

    asset_buffers_destroy()

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

renderer_dx_wait_idle :: proc() {
    dx.fence_wait(renderer_dx.frame_fence_gfx, renderer_dx.frame_val)
}

renderer_dx_resize_window :: proc(new_size: uvec2) {
    dx.swapchain_resize(renderer_dx.render_context, &renderer_dx.swapchain, new_size.x, new_size.y)
}

renderer_dx_resize_view :: proc(view: ^Render_View, new_size: uvec2) {
    dx.fence_wait(renderer_dx.frame_fence_gfx, renderer_dx.frame_val)
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