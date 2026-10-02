package blimp

import "vendor:directx/d3d12"
import "dx"

// The post chain (docs/rendering.md: tonemap → LUT → quantize + dither → upscale), one fullscreen pass
// (post.slang): each view's linear HDR scene target → its display target, which ImGui samples as-is.
// No LUT yet.
Render_Post :: struct {
    shader: dx.Compiled_Shader,
    pso:    dx.Pipeline_State,
}
render_post: Render_Post

render_post_init :: proc() {
    render_post.shader = dx.slang_compiler_compile_shader(renderer_dx.slang_compiler, "post", "vert_main", "frag_main")

    opts := dx.PIPELINE_OPTIONS_DEFAULT
    opts.cull_mode   = .NONE
    opts.depth_test  = false
    opts.depth_write = false
    opts.dsv_format  = .UNKNOWN   // no DSV: the scene's depth is at the scene size, the display target isn't
    render_post.pso = dx.pipeline_create_graphics_pso(renderer_dx.render_context, renderer_dx.root_signature, render_post.shader, opts)
}

render_post_shutdown :: proc() {
    dx.pipeline_destroy_pso(render_post.pso)
    dx.slang_compiler_destroy_shader(render_post.shader)
}

// Resolves the view's scene target into its display target. Runs right after render_view_draw, so the
// view's root signature and constants are still bound; sets the display size's viewport. Leaves the
// display target bound and the scene depth readable (depthTextureSlot) for the debug lines.
render_post_draw :: proc(view: ^Render_View) {
    cmd := renderer_dx.cmd_gfx
    dx.texture_transition(cmd, &view.target.hdr_tex, {.PIXEL_SHADING}, {.SHADER_RESOURCE}, .SHADER_RESOURCE)
    dx.texture_transition(cmd, &view.target.depth_tex, {.PIXEL_SHADING}, {.SHADER_RESOURCE}, .SHADER_RESOURCE)
    dx.texture_transition(cmd, &view.target.tex, {.RENDER_TARGET}, {.RENDER_TARGET}, .RENDER_TARGET)
    cmd.handle->OMSetRenderTargets(1, &view.target.rtv.cpu_handle, false, nil)

    dx_viewport := d3d12.VIEWPORT{Width = f32(view.target.width), Height = f32(view.target.height), MaxDepth = 1.0}
    scissor     := d3d12.RECT{right = i32(view.target.width), bottom = i32(view.target.height)}
    cmd.handle->RSSetViewports(1, &dx_viewport)
    cmd.handle->RSSetScissorRects(1, &scissor)

    cmd.handle->SetPipelineState(render_post.pso.handle)
    cmd.handle->IASetPrimitiveTopology(.TRIANGLELIST)
    cmd.handle->DrawInstanced(3, 1, 0, 0)
}
