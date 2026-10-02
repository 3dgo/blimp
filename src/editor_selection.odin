package blimp

import hm "core:container/handle_map"
import "core:math"
import "core:math/linalg"

// Editor selection. Membership is a flag on each entity (`selected`, hidden + noserialize): undo
// snapshots carry it, delete takes it along, pasted entities start unselected, and it never reaches
// scene files or the clipboard. The world's `active` entity is the one the inspector shows and the
// gizmo pivots on — the last one clicked; it's always selected when valid.
//
// Input (ui_view.odin, ui_entity_panels.odin): click or marquee replaces the selection; Ctrl toggles
// (Unity); Shift in the entity list selects a range from the anchor.

selection_has :: proc(w: ^World, h: Entity_Handle) -> bool {
    e, ok := entity_get(w, h)
    return ok && e.selected
}

selection_set :: proc(w: ^World, h: Entity_Handle, on: bool) {
    e, ok := entity_get(w, h)
    if !ok do return
    e.selected = on
    if on do w.active = h
    else if w.active == h do w.active = selection_first(w)
}

selection_toggle :: proc(w: ^World, h: Entity_Handle) {
    selection_set(w, h, !selection_has(w, h))
}

selection_clear :: proc(w: ^World) {
    it := hm.iterator_make(&w.entities)
    for e, _ in hm.iterate(&it) do e.selected = false
    w.active = {}
}

// Just `h` (nothing, if `h` isn't an entity).
selection_only :: proc(w: ^World, h: Entity_Handle) {
    selection_clear(w)
    selection_set(w, h, true)
}

selection_count :: proc(w: ^World) -> (n: int) {
    it := hm.iterator_make(&w.entities)
    for e, _ in hm.iterate(&it) do if e.selected do n += 1
    return
}

// The selected handles, in entity-map order.
selection_handles :: proc(w: ^World, allocator := context.temp_allocator) -> []Entity_Handle {
    out := make([dynamic]Entity_Handle, allocator)
    it := hm.iterator_make(&w.entities)
    for e, h in hm.iterate(&it) do if e.selected do append(&out, h)
    return out[:]
}

@(private="file")
selection_first :: proc(w: ^World) -> Entity_Handle {
    it := hm.iterator_make(&w.entities)
    for e, h in hm.iterate(&it) do if e.selected do return h
    return {}
}

// Screen rectangle an entity covers in the view: its world-space bounding box, projected. False when it
// has no model or is entirely behind the camera. Used by marquee selection (a crossing test: any
// overlap selects, as in 3ds Max — on the box, not the exact triangles).
entity_screen_rect :: proc(ev: ^Editor_View, e: ^Entity) -> (lo, hi: vec2, ok: bool) {
    model, has := asset_system.models[e.model]
    if !has do return editor_icon_rect(ev, e)   // a camera / light: its icon
    if !entity_drawn(e) do return   // a marquee doesn't catch what isn't drawn
    mlo, mhi := model_bounds(model)
    M := entity_transform(e)
    lo, hi = {max(f32), max(f32)}, {min(f32), min(f32)}
    for i in 0 ..< 8 {
        corner := vec3{(i & 1) != 0 ? mhi.x : mlo.x, (i & 2) != 0 ? mhi.y : mlo.y, (i & 4) != 0 ? mhi.z : mlo.z}
        p, front := ui_world_to_screen(ev, transform_point(M, corner))
        if !front do continue
        lo = linalg.min(lo, p)
        hi = linalg.max(hi, p)
        ok = true
    }
    return
}

// What a viewport click or marquee does to the selection, from the modifiers held at release:
// none = Replace, Shift = Add, Ctrl+Shift = Remove, Ctrl = Toggle.
Selection_Op :: enum u8 { Replace, Add, Remove, Toggle }

selection_op_from_modifiers :: proc(ctrl, shift: bool) -> Selection_Op {
    switch {
    case ctrl && shift: return .Remove
    case shift:         return .Add
    case ctrl:          return .Toggle
    }
    return .Replace
}

@(private="file")
selection_apply :: proc(w: ^World, h: Entity_Handle, op: Selection_Op) {
    switch op {
    case .Replace, .Add: selection_set(w, h, true)
    case .Remove:        selection_set(w, h, false)
    case .Toggle:        selection_toggle(w, h)
    }
}

// A click at screen point `p` in the view, on what's under it. Replace with nothing under the cursor
// clears the selection; the other ops leave it alone on a miss.
selection_click :: proc(ev: ^Editor_View, p: vec2, op: Selection_Op) {
    w := ev.view.world
    // A camera / light icon under the cursor wins: it's drawn in front of every mesh.
    target, ok := editor_icon_pick(ev, p)
    if !ok {
        ray := camera_ray(ev.view.camera, p.x - ev.screen_min.x, p.y - ev.screen_min.y, ev.screen_size.x, ev.screen_size.y)
        hit: Pick_Result
        hit, ok = pick_entity(w, ray)
        target = hit.entity
    }
    if op == .Replace do selection_clear(w)
    if ok do selection_apply(w, target, op)
}

// A marquee over screen rectangle lo..hi, on every entity whose box touches it (crossing).
selection_marquee :: proc(ev: ^Editor_View, lo, hi: vec2, op: Selection_Op) {
    w := ev.view.world
    if op == .Replace do selection_clear(w)
    it := hm.iterator_make(&w.entities)
    for e, h in hm.iterate(&it) {
        elo, ehi := entity_screen_rect(ev, e) or_continue
        if ehi.x < lo.x || elo.x > hi.x || ehi.y < lo.y || elo.y > hi.y do continue
        selection_apply(w, h, op)
    }
}


// Centre of the selection's combined world bounds (entities without a model count as their position).
// The gizmo's pivot in Selection Center mode. Origin if nothing is selected.
selection_center :: proc(w: ^World) -> vec3 {
    lo := vec3{max(f32), max(f32), max(f32)}
    hi := vec3{min(f32), min(f32), min(f32)}
    any := false
    it := hm.iterator_make(&w.entities)
    for e, _ in hm.iterate(&it) {
        if !e.selected do continue
        if !entity_grow_bounds(e, &lo, &hi) {
            lo, hi = linalg.min(lo, e.position), linalg.max(hi, e.position)
        }
        any = true
    }
    return any ? (lo + hi) * 0.5 : {}
}

// Ctrl+D: copy every selected entity in place (unique names) and select the copies instead, so the
// next move takes them and leaves the originals where they were. The caller takes the undo snapshot.
selection_duplicate :: proc(w: ^World) -> (count: int) {
    for h in selection_handles(w) {
        copy := world_clone(w, h) or_continue   // the copy carries the selected flag
        if src, ok := entity_get(w, h); ok do src.selected = false
        if w.active == h do w.active = copy
        count += 1
    }
    return
}


Pick_Result :: struct {
    entity: Entity_Handle,
    t: f32,
    point: vec3,
}

pick_entity :: proc(world: ^World, r: Ray) -> (Pick_Result, bool) {
    best: Pick_Result
    best.t = max(f32)
    found := false

    it := hm.iterator_make(&world.entities)
    for e, h in hm.iterate(&it) {
        if !entity_drawn(e) do continue   // can't pick what isn't drawn
        model, ok := asset_system.models[e.model]
        if !ok do continue

        M := entity_transform(e)
        Minv := linalg.inverse(M)
        obj_ray := Ray {
            origin = transform_point(Minv, r.origin),
            dir = transform_dir(Minv, r.dir),
        }

        for mesh_idx in model.meshes {
            bvh := &asset_system.mesh_bvhs[mesh_idx]
            if hit, hit_ok := bvh_closest_hit(bvh, obj_ray); hit_ok && hit.t < best.t {
                best.entity = h
                best.t = hit.t
                found = true
            }
        }
    }
    if found do best.point = r.origin + best.t * r.dir
    return best, found
}

// Appends `v`'s editor overlay to this frame's debug lines and records its range on the view: the
// selection boxes, in every view of the world: the active entity pale green, the rest of the selection green.
pick_view_debug_lines :: proc(v: ^Render_View) {
    v.debug_first = u32(len(debug_draw.verts))
    defer v.debug_count = u32(len(debug_draw.verts)) - v.debug_first
    if editor_view(v).game_view || v == ui.game do return   // G or game mode: none of the editor's lines in this view
    if editor_view(v).show_probes {
        g := &world_level(v.world).probes   // a play world shows its level's, lit by its own group scales
        probe_grid_debug_lines(g, probe_layer_scales(g, light_group_scales(v.world, timer_sec_since_start())), math.pow(2, v.world.settings.exposure))
    }

    it := hm.iterator_make(&v.world.entities)
    for e, h in hm.iterate(&it) {
        // Both bright enough to read on dark scenes; the active one paler (whiter), the rest saturated.
        sel_color := h == v.world.active ? vec4{0.7, 1, 0.7, 1} : vec4{0.15, 0.9, 0.3, 1}
        editor_entity_shapes(e, e.selected ? sel_color : nil)   // camera frustum / light reach (editor_shapes.odin)
        if !e.selected || !entity_drawn(e) do continue          // hidden / disabled: no box either
        pick_draw_entity_bounds(e, sel_color)
    }
}

pick_draw_entity_bounds :: proc(e: ^Entity, color := vec4{0.2, 1, 0.3, 1}) {
    model, ok := asset_system.models[e.model]
    if !ok do return
    lo, hi := model_bounds(model)
    M := entity_transform(e)
    c: [8]vec3
    for i in 0 ..< 8 {
        x := (i & 1) != 0 ? hi.x : lo.x
        y := (i & 2) != 0 ? hi.y : lo.y
        z := (i & 4) != 0 ? hi.z : lo.z
        c[i] = transform_point(M, {x, y, z})
    }
    edges := [12][2]int{ {0,1},{2,3},{4,5},{6,7}, {0,2},{1,3},{4,6},{5,7}, {0,4},{1,5},{2,6},{3,7} }
    for edge in edges do debug_line(c[edge[0]], c[edge[1]], color)
}