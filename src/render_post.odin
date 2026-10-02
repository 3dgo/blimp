package blimp

import "dx"

// The post chain (docs/rendering.md: tonemap → LUT → quantize + dither → upscale). Today only the
// tonemap: each view's linear HDR scene target → its display target, which ImGui samples as-is.
Render_Post :: struct {
    tonemap_shader: dx.Compiled_Shader,
    tonemap_pso:    dx.Pipeline_State,
}
render_post: Render_Post

render_post_init :: proc() {
    render_post.tonemap_shader = dx.slang_compiler_compile_shader(renderer_dx.slang_compiler, "tonemap", "vert_main", "frag_main")

    // A fullscreen triangle. The depth buffer stays bound (untested, unwritten) so debug lines drawn
    // after it can still test against the scene.
    opts := dx.PIPELINE_OPTIONS_DEFAULT
    opts.cull_mode   = .NONE
    opts.depth_test  = false
    opts.depth_write = false
    render_post.tonemap_pso = dx.pipeline_create_graphics_pso(renderer_dx.render_context, renderer_dx.root_signature, render_post.tonemap_shader, opts)
}

render_post_shutdown :: proc() {
    dx.pipeline_destroy_pso(render_post.tonemap_pso)
    dx.slang_compiler_destroy_shader(render_post.tonemap_shader)
}

// Resolves the view's scene target into its display target. Runs right after render_view_draw, so the
// view's viewport, scissor, root signature and constants are still bound; leaves the display target and
// the depth buffer bound for the debug lines.
render_post_draw :: proc(view: ^Render_View) {
    cmd := renderer_dx.cmd_gfx
    dx.texture_transition(cmd, &view.target.hdr_tex, {.PIXEL_SHADING}, {.SHADER_RESOURCE}, .SHADER_RESOURCE)
    dx.texture_transition(cmd, &view.target.tex, {.RENDER_TARGET}, {.RENDER_TARGET}, .RENDER_TARGET)
    cmd.handle->OMSetRenderTargets(1, &view.target.rtv.cpu_handle, false, &view.target.dsv.cpu_handle)

    cmd.handle->SetPipelineState(render_post.tonemap_pso.handle)
    cmd.handle->IASetPrimitiveTopology(.TRIANGLELIST)
    cmd.handle->DrawInstanced(3, 1, 0, 0)
}
