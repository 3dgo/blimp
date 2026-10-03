package blimp

import "dx"

// The GPU copy of a world's baked probes (world_probes.odin): its SH and depth buffers, and the atlas
// texture the Bake and Resources windows show. Created with the world's render mirror (world_render_create)
// and staged by world_render_upload; replaced whole after a bake.

// The probe buffer (and the atlas texture, when there is one) for w.probes, staged next frame. Nothing when not baked.
world_render_probes_create :: proc(w: ^World) {
    if len(w.probes.probes) == 0 do return
    w.render.probes = buffers_resource_create(size_of(Probe_SH), u32(len(w.probes.probes)), &renderer_dx.resource_heap)
    w.render.probe_depth = buffers_resource_create(size_of(Probe_Depth), u32(len(w.probes.depth)), &renderer_dx.resource_heap)
    if a := w.probes.atlas; len(a.pixels) > 0 {
        w.render.probe_atlas    = buffers_texture_create(a.width, a.height, dx_format(a.format))
        w.render.probe_atlas_ui = dx.descriptor_heap_register_srv(renderer_dx.render_context, &renderer_dx.ui_heap, w.render.probe_atlas.resource)
    }
    w.render.probes_upload = true
}

world_render_probes_destroy :: proc(w: ^World) {
    if w.render.probes.resource.handle == nil do return
    dx.descriptor_heap_free(&renderer_dx.resource_heap, w.render.probes.resource_view.heap_slot)
    buffers_resource_destroy(w.render.probes)
    dx.descriptor_heap_free(&renderer_dx.resource_heap, w.render.probe_depth.resource_view.heap_slot)
    buffers_resource_destroy(w.render.probe_depth)
    if w.render.probe_atlas.resource.handle != nil {
        dx.descriptor_heap_free(&renderer_dx.resource_heap, w.render.probe_atlas.resource_view.heap_slot)
        dx.descriptor_heap_free(&renderer_dx.ui_heap, w.render.probe_atlas_ui.heap_slot)
        buffers_resource_destroy(w.render.probe_atlas)
    }
    w.render.probes, w.render.probe_depth, w.render.probe_atlas, w.render.probe_atlas_ui = {}, {}, {}, {}
}

// After w.probes is replaced on a world already on screen (a bake). Waits for the GPU, so call it
// outside the frame (UI or remote command), never from renderer_dx_draw_frame.
world_render_probes_recreate :: proc(w: ^World) {
    renderer_dx_wait_idle()
    world_render_probes_destroy(w)
    world_render_probes_create(w)
}
