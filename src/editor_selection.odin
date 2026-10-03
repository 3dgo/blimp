package blimp

import hm "core:container/handle_map"
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
    if on do editor_world(w).active = h
    else if editor_world(w).active == h do editor_world(w).active = selection_first(w)
}

selection_toggle :: proc(w: ^World, h: Entity_Handle) {
    selection_set(w, h, !selection_has(w, h))
}

selection_clear :: proc(w: ^World) {
    it := hm.iterator_make(&w.entities)
    for e, _ in hm.iterate(&it) do e.selected = false
    editor_world(w).active = {}
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
    corners, has := entity_world_corners(e)
    if !has do return editor_icon_rect(ev, e)   // a camera / light: its icon
    if !entity_drawn(e) do return   // a marquee doesn't catch what isn't drawn
    lo, hi = {max(f32), max(f32)}, {min(f32), min(f32)}
    for c in corners {
        p, front := world_to_screen(ev, c)
        if !front do continue
        lo = linalg.min(lo, p)
        hi = linalg.max(hi, p)
        ok = true
    }
    return
}

// How the selection draws (boxes, shapes, icon rings): bright enough to read on dark scenes, the active
// entity paler (whiter), the rest saturated.
SELECTION_ACTIVE_COLOR :: vec4{0.7, 1, 0.7, 1}
SELECTION_COLOR        :: vec4{0.15, 0.9, 0.3, 1}

selection_color :: proc(w: ^World, h: Entity_Handle) -> vec4 {
    return h == editor_world(w).active ? SELECTION_ACTIVE_COLOR : SELECTION_COLOR
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

// A click at screen point `p` in the view, on what's under it (view_pick). Replace with nothing under the
// cursor clears the selection; the other ops leave it alone on a miss.
selection_click :: proc(ev: ^Editor_View, p: vec2, op: Selection_Op) {
    w := ev.view.world
    target, ok := view_pick(ev, p)
    if op == .Replace do selection_clear(w)
    if ok do selection_apply(w, target.entity, op)
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
        if editor_world(w).active == h do editor_world(w).active = copy
        count += 1
    }
    return
}

Pick_Result :: struct {
    entity: Entity_Handle,
    t: f32,
    point: vec3,
    icon: bool,   // view_pick: it was the entity's icon, not its mesh (t and point unset)
}

// The ray through screen point `p` (ImGui screen coordinates) of ev's image.
view_mouse_ray :: proc(ev: ^Editor_View, p: vec2) -> Ray {
    return camera_ray(ev.view.camera, p.x - ev.screen_min.x, p.y - ev.screen_min.y, ev.screen_size.x, ev.screen_size.y)
}

// What's under screen point `p` in ev's view — what a click there selects: a camera / light icon wins
// (it's drawn in front of every mesh), else the nearest drawn mesh along the ray. Every pick goes through
// this: clicks, the context menu, blimpctl pick.
view_pick :: proc(ev: ^Editor_View, p: vec2) -> (Pick_Result, bool) {
    if h, ok := editor_icon_pick(ev, p); ok do return {entity = h, icon = true}, true
    return pick_entity(ev.view.world, view_mouse_ray(ev, p))
}

PASTE_SPAWN_DISTANCE :: 5.0  // units in front of the camera when a paste ray hits nothing

// Where something pasted at screen point `p` lands: the surface under it, or PASTE_SPAWN_DISTANCE units in
// front of the camera along the ray when there's none.
view_paste_point :: proc(ev: ^Editor_View, p: vec2) -> vec3 {
    ray := view_mouse_ray(ev, p)
    if hit, ok := pick_entity(ev.view.world, ray); ok do return hit.point
    return ray.origin + PASTE_SPAWN_DISTANCE * ray.dir
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
            if t, hit_ok := bvh_closest_hit(bvh, obj_ray); hit_ok && t < best.t {
                best.entity = h
                best.t = t
                found = true
            }
        }
    }
    if found do best.point = r.origin + best.t * r.dir
    return best, found
}

// The selection box: `e`'s model box as debug lines.
selection_draw_bounds :: proc(e: ^Entity, color: vec4) {
    if c, ok := entity_world_corners(e); ok do debug_box_corners(c, color)
}

// The editor's delete: moves the active entity off `h` first, then removes it from `w`. (Lua's World.remove
// goes straight to world_remove; a stale `active` just shows nothing until the next click.)
selection_remove_entity :: proc(w: ^World, h: Entity_Handle) {
    selection_set(w, h, false)
    world_remove(w, h)
}

// The editor's paste: adds the [entity] blocks in `text` to `w` as one undo step and selects them. Every
// paste — Ctrl+V, the context menu, a template, blimpctl — places the same way:
// - at a point: one block lands there, keeping its rotation and scale (a spot light still points down);
//   several keep their layout, moved as a group so their centre lands there;
// - no point (blimpctl paste): exactly where the text says.
// Returns how many entities it added.
selection_paste :: proc(w: ^World, text: string, at: Maybe(vec3) = nil) -> int {
    if entity_count_blocks(text) == 0 do return 0
    undo_push(w)
    handles := make([dynamic]Entity_Handle, context.temp_allocator)
    scene_load_from_text(w, text, &handles)
    if pos, ok := at.?; ok {
        centre: vec3
        for h in handles do if e, eok := entity_get(w, h); eok do centre += e.position
        centre /= f32(max(len(handles), 1))
        for h in handles do if e, eok := entity_get(w, h); eok do e.position = pos + (e.position - centre)
    }
    selection_clear(w)
    for h in handles do selection_set(w, h, true)
    return len(handles)
}
