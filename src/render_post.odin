package blimp

import "vendor:directx/d3d12"
import "vendor:directx/dxgi"
import "dx"

// The post chain (docs/rendering.md: tonemap → LUT → quantize + dither → upscale), fullscreen passes
// (post.slang): each view's linear HDR scene target → its display target, which ImGui samples as-is.
//   .Retro  signal (scene size) → [bloom across → bloom down, scene size, CRT bloom on] → upscale (display size)
//   .Clean  signal, straight into the display target (the scene is display-sized, nothing is quantized)
// No LUT yet.
Render_Post :: struct {
    signal, bloom_h, bloom_v, upscale: Shader_Pipeline,
}
render_post: Render_Post

render_post_init :: proc() {
    pass :: proc(entry: string, format: dxgi.FORMAT) -> Shader_Pipeline {
        opts := dx.PIPELINE_OPTIONS_DEFAULT
        opts.cull_mode   = .NONE
        opts.depth_test  = false
        opts.depth_write = false
        opts.rtv_format  = format
        opts.dsv_format  = .UNKNOWN   // no DSV: the scene's depth is at the scene size, the display target isn't
        return shader_pipeline_create("post", "vert_main", entry, opts)
    }
    render_post.signal  = pass("frag_signal",  .R8G8B8A8_UNORM)   // the display format: it's also the clean view's output
    render_post.bloom_h = pass("frag_bloom_h", VIEW_HDR_FORMAT)
    render_post.bloom_v = pass("frag_bloom_v", VIEW_HDR_FORMAT)
    render_post.upscale = pass("frag_upscale", .R8G8B8A8_UNORM)
}

render_post_shutdown :: proc() {
    for p in ([?]Shader_Pipeline{render_post.signal, render_post.bloom_h, render_post.bloom_v, render_post.upscale}) do shader_pipeline_destroy(p)
}

// Resolves the view's scene target into its display target. Runs right after render_view_draw, so the
// view's root signature and constants are still bound. Leaves the display target bound at the display
// size's viewport, and the scene depth readable (depthTextureSlot) for the debug lines.
render_post_draw :: proc(view: ^Render_View) {
    cmd := renderer_dx.cmd_gfx
    t := &view.target
    dx.texture_transition(cmd, &t.hdr_tex, {.PIXEL_SHADING}, {.SHADER_RESOURCE}, .SHADER_RESOURCE)
    dx.texture_transition(cmd, &t.depth_tex, {.PIXEL_SHADING}, {.SHADER_RESOURCE}, .SHADER_RESOURCE)
    cmd.handle->IASetPrimitiveTopology(.TRIANGLELIST)

    if t.post_targets {
        _, crt := render_view_retro(view)
        render_post_pass(cmd, render_post.signal, &t.signal_tex, t.signal_rtv, t.scene_width, t.scene_height)
        dx.texture_transition(cmd, &t.signal_tex, {.PIXEL_SHADING}, {.SHADER_RESOURCE}, .SHADER_RESOURCE)
        if crt.on && crt.bloom {
            render_post_pass(cmd, render_post.bloom_h, &t.bloom_tex[0], t.bloom_rtv[0], t.scene_width, t.scene_height)
            dx.texture_transition(cmd, &t.bloom_tex[0], {.PIXEL_SHADING}, {.SHADER_RESOURCE}, .SHADER_RESOURCE)
            render_post_pass(cmd, render_post.bloom_v, &t.bloom_tex[1], t.bloom_rtv[1], t.scene_width, t.scene_height)
            dx.texture_transition(cmd, &t.bloom_tex[1], {.PIXEL_SHADING}, {.SHADER_RESOURCE}, .SHADER_RESOURCE)
        }
        render_post_pass(cmd, render_post.upscale, &t.tex, t.rtv, t.width, t.height)
    } else {
        render_post_pass(cmd, render_post.signal, &t.tex, t.rtv, t.width, t.height)
    }
}

// One fullscreen triangle of `pass` into `target` (made a render target) at `width` × `height`.
@(private="file")
render_post_pass :: proc(cmd: dx.Command_List, pass: Shader_Pipeline, target: ^dx.Resource, rtv: dx.Resource_View, width, height: u32) {
    dx.texture_transition(cmd, target, {.RENDER_TARGET}, {.RENDER_TARGET}, .RENDER_TARGET)
    rtv_handle := rtv.cpu_handle
    cmd.handle->OMSetRenderTargets(1, &rtv_handle, false, nil)
    dx_viewport := d3d12.VIEWPORT{Width = f32(width), Height = f32(height), MaxDepth = 1.0}
    scissor     := d3d12.RECT{right = i32(width), bottom = i32(height)}
    cmd.handle->RSSetViewports(1, &dx_viewport)
    cmd.handle->RSSetScissorRects(1, &scissor)
    cmd.handle->SetPipelineState(pass.pso.handle)
    cmd.handle->DrawInstanced(3, 1, 0, 0)
}
