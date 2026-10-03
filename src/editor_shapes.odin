package blimp

import "core:math"

// What an entity is besides its model, made visible in the editor: a camera's frustum and a light's
// reach as scene lines (render_debug_draw.odin, drawn into each view's editor lines by ui_view_debug_lines);
// its icon is editor_icons.odin. Cameras and lights have no mesh, so
// without these they'd be invisible. Selected ones draw in the selection colours.

EDITOR_SHAPE_DEPTH       :: 5.0          // perspective frustums are drawn at most this deep, so a far plane of 1000 doesn't fill the view
EDITOR_SHAPE_ORTHO_DEPTH :: 200.0        // orthographic boxes: their real depth, within reason
EDITOR_SHAPE_ASPECT      :: 16.0 / 9.0   // a camera's real aspect comes from its target; the PS1 target is 16:9

EDITOR_SHAPE_CAMERA_COLOR :: vec4{0.8, 0.8, 0.85, 1}
EDITOR_SHAPE_LIGHT_COLOR  :: vec4{1, 0.8, 0.35, 1}

// `selected_color` is nil for an unselected entity, whose shape draws dimmed so a city's worth of reach
// spheres stays in the background; the selected ones stand out.
editor_entity_shapes :: proc(e: ^Entity, selected_color: Maybe(vec4)) {
    if .Enabled not_in e.basic_flags || .Hidden in e.basic_flags do return
    if e.camera_type == .None && e.light_type == .None do return
    right, up, forward := debug_axes_of(e.rotation)
    p := e.position

    cam_col := selected_color.? or_else editor_dim(EDITOR_SHAPE_CAMERA_COLOR)
    switch e.camera_type {
    case .None:
    case .Perspective:
        tan_half := math.tan(math.to_radians(e.fov) * 0.5)
        near, far := e.range.x, min(e.range.y, EDITOR_SHAPE_DEPTH)
        debug_frustum(p, e.rotation, near, far,
            {near * tan_half * EDITOR_SHAPE_ASPECT, near * tan_half}, {far * tan_half * EDITOR_SHAPE_ASPECT, far * tan_half}, cam_col)
    case .Orthographic:
        // A box doesn't widen with depth, so it's drawn at its real depth: it shows exactly what's seen.
        half := vec2{e.size.y * 0.5 * EDITOR_SHAPE_ASPECT, e.size.y * 0.5}
        debug_frustum(p, e.rotation, e.range.x, min(e.range.y, EDITOR_SHAPE_ORTHO_DEPTH), half, half, cam_col)
    }

    col := selected_color.? or_else editor_dim(editor_light_color(e))
    // Where the falloff starts (range.x, clamped to the reach): the same shape as the reach, dimmer.
    // Dim shapes (falloff start, inner cone / radius) are skipped where they'd coincide with the bright
    // ones: at 0 the start collapses onto the light, and at or past the outer value it would draw over it.
    start := e.range.x
    has_start := start > 0 && start < e.range.y
    switch e.light_type {
    case .None:
    case .Directional:
        // The direction it shines, with a small ring around its tail.
        debug_arrow(p, p + forward * 1.5, col, 0.3)
        debug_circle(p, right, up, 0.25, col)
        if selected_color != nil && e.shadow {   // and (selected) the box its shadow map covers (light_shadow_cameras)
            h := e.size * 0.5
            debug_frustum(p, e.rotation, -h.z, h.z, h.xy, h.xy, editor_dim(col))
        }
    case .Point:
        debug_sphere(p, e.range.y, col, e.rotation)   // its reach (falloff radius)
        if has_start do debug_sphere(p, start, editor_dim(col), e.rotation)
    case .Spot:
        half := math.to_radians(e.fov) * 0.5
        debug_cone(p, forward, e.range.y, half, col)   // out to its reach
        if has_start do debug_circle(p + forward * (start * math.cos(half)), right, up, start * math.sin(half), editor_dim(col))   // just the rim: a second cone's sides would sit on the first's
        if selected_color != nil && e.inner_fov < e.fov {   // and its full-intensity core, like Unreal's inner cone
            inner := math.to_radians(e.inner_fov) * 0.5
            debug_cone(p, forward, e.range.y, inner, editor_dim(col), cap = false)
        }
    case .Cylinder:
        // Its beam out to its reach, an arrow down the axis, and (selected) its full-intensity core.
        r := max(e.radius, 0)
        debug_cylinder(p, forward, e.range.y, r, col)
        debug_arrow(p, p + forward * min(e.range.y, 1.5), col, 0.3)
        if has_start do debug_circle(p + forward * start, right, up, r, editor_dim(col))   // a ring: its sides would sit on the beam's
        if selected_color != nil && e.inner_radius < r {
            debug_cylinder(p, forward, e.range.y, max(e.inner_radius, 0), editor_dim(col))
        }
    }
}

// A light's own colour, brightened so a dim one still reads (a black light falls back to amber).
editor_light_color :: proc(e: ^Entity) -> vec4 {
    peak := max(e.color.r, e.color.g, e.color.b)
    if peak <= 0.001 do return EDITOR_SHAPE_LIGHT_COLOR
    return {e.color.r / peak, e.color.g / peak, e.color.b / peak, 1}
}


// An unselected shape's colour. Debug lines don't blend, so dimming darkens rather than fades.
EDITOR_SHAPE_DIM :: 0.4

@(private="file")
editor_dim :: proc(c: vec4) -> vec4 {
    return {c.r * EDITOR_SHAPE_DIM, c.g * EDITOR_SHAPE_DIM, c.b * EDITOR_SHAPE_DIM, c.a}
}

// ============================ Probes ============================

PROBE_DEBUG_SPOKE :: 0.12   // fraction of the spacing each spoke reaches

// Each probe as six short spokes along ±X/±Y/±Z, coloured by the irradiance a surface facing that
// way would get with its layers × `scales`, times `exposure` (the world's 2^EV) and clamped, so it reads
// like the lit scene.
probe_grid_debug_lines :: proc(g: ^Probe_Grid, scales: Probe_Layer_Scales, exposure: f32) {
    dirs := [6]vec3{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
    len_ := g.spacing * PROBE_DEBUG_SPOKE
    for z in 0..<g.dims.z do for y in 0..<g.dims.y do for x in 0..<g.dims.x {
        p := probe_position(g, x, y, z)
        i := probe_index(g, x, y, z)
        for d in dirs {
            e := exposure * probe_eval(g, i, d, scales)
            c := vec4{linear_to_srgb(clamp(e.x, 0, 1)), linear_to_srgb(clamp(e.y, 0, 1)), linear_to_srgb(clamp(e.z, 0, 1)), 1}
            debug_line(p, p + d * len_, c)
        }
    }
}
