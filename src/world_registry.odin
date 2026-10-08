package blimp

import "core:slice"
import "core:strings"
import "core:path/filepath"

// Every open world, and every view onto one. At startup only Game Settings' start level is open (ui_game_start);
// the user opens scenes (.level) and kits (.gltf) from the Worlds window. Both open the same way — a World plus a Render_View in its
// own world window — and differ only in how the World is filled and whether it has a save_path.
// Each is individually allocated so its address is stable (views, selection and panels hold ^World /
// ^Render_View; a [dynamic]World would move them on grow).
//
// This file is the lists and their world-layer half: building, finding, freeing. Opening, playing and
// closing also touch the renderer, physics, sound, Lua, undo and the UI; app_lifecycle.odin does those
// in order and calls in here for the world part.
worlds: [dynamic]^World
views:  [dynamic]^Render_View

@(private="file") next_view_id: u32 = 1

// The viewport the user last focused. Its world is the "active world": the target of Ctrl+C/V.
// nil when no world is open. Written only by view_activate.
active_view: ^Render_View

// Closing is deferred to the start of the next frame (app_process_closes): frames still in flight may be
// reading the world's buffers / the view's target, and this frame's ImGui draw data may reference the target.
pending_close_views:  [dynamic]^Render_View
pending_close_worlds: [dynamic]^World

// The active world, or nil if nothing is open.
active_world :: proc() -> ^World {
    return active_view != nil ? active_view.world : nil
}

// Makes `v` the active view (nil: falls back to any open one).
view_activate :: proc(v: ^Render_View) {
    active_view = v
    if active_view == nil && len(views) > 0 do active_view = views[0]
}

// Makes `w` the active world (e.g. the user selected in a panel pinned to it) by activating its
// first view. No-op if it's already active.
world_activate :: proc(w: ^World) {
    if active_world() == w do return
    for v in views do if v.world == w { view_activate(v); return }
}

// Frees the registry's lists. Every world and view must already be closed (app_close_all).
world_registry_shutdown :: proc() {
    delete(worlds)
    delete(views)
    delete(pending_close_views)
    delete(pending_close_worlds)
}

// ============================ Open ============================

// A scene file as a new registered world. Editable and saveable back to `path`.
world_open_scene :: proc(path: string) -> ^World {
    w := new(World, app.allocators.perm)
    world_init(w)
    w.title     = strings.clone(filepath.base(path), app.allocators.perm)
    w.save_path = strings.clone(path, app.allocators.perm)
    w.source    = w.save_path
    scene_load(w, path)
    append(&worlds, w)
    return w
}

// A kit (glTF) as a new registered world: one entity per mesh node of the glTF's scene, where the DCC
// placed it. Editable, but has no save_path — a kit can't be written back to its glTF.
world_open_kit :: proc(kit: ^Kit) -> ^World {
    w := new(World, app.allocators.perm)
    world_init(w)
    w.title = strings.clone(filepath.base(kit.path), app.allocators.perm)
    w.source = strings.clone(kit.path, app.allocators.perm)
    for n in kit.nodes do world_add_named(w, n.name, n.model, n.position)
    append(&worlds, w)
    return w
}

// Adds a view (already created by the renderer, app_view_open) to the list and gives it its stable id.
view_register :: proc(v: ^Render_View) {
    v.id = next_view_id
    next_view_id += 1
    append(&views, v)
}

// The open world opened from `path` (scene or kit), if any.
world_find_open :: proc(path: string) -> ^World {
    for w in worlds do if w.source == path do return w
    return nil
}

// ============================ Close ============================

// Ask to close a view; it happens at the start of the next frame. Closing a world's last view closes
// the world too.
view_request_close :: proc(v: ^Render_View) {
    if !slice.contains(pending_close_views[:], v) do append(&pending_close_views, v)
}

// Ask to close a world and all its views; happens at the start of the next frame.
world_request_close :: proc(w: ^World) {
    if !slice.contains(pending_close_worlds[:], w) do append(&pending_close_worlds, w)
}

// Unregisters and frees a view (its renderer and UI state are already gone).
view_free :: proc(v: ^Render_View) {
    if i, found := slice.linear_search(views[:], v); found do ordered_remove(&views, i)
    if active_view == v do active_view = nil   // app_process_closes re-picks it once everything's closed
    free(v, app.allocators.perm)
}

// Unregisters and frees a world (every system's state for it is already gone).
world_free :: proc(w: ^World) {
    if i, found := slice.linear_search(worlds[:], w); found do ordered_remove(&worlds, i)
    world_shutdown(w)
    delete(w.title, app.allocators.perm)
    if w.save_path != "" do delete(w.save_path, app.allocators.perm)
    if w.save_path == "" do delete(w.source, app.allocators.perm)   // a scene's source is its save_path
    free(w, app.allocators.perm)
}

// Whether any view still shows `w`.
world_viewed :: proc(w: ^World) -> bool {
    for v in views do if v.world == w do return true
    return false
}
