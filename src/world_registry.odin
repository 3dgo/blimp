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
// (`game_world` in world.odin is not one of these: it's Lua's target until world scripts exist, and
// the editor doesn't show it.)
worlds: [dynamic]^World
views:  [dynamic]^Render_View

@(private="file") next_view_id: u32 = 1

// The viewport the user last focused. Its world is the "active world": the target of Ctrl+C/V and
// what follow-mode entity panels show. nil when no world is open.
active_view: ^Render_View

// Closing is deferred to the top of the next UI frame: frames still in flight may be reading the
// world's buffers / the view's target, and this frame's ImGui draw data may reference the target.
@(private="file") pending_close_views:  [dynamic]^Render_View
@(private="file") pending_close_worlds: [dynamic]^World

// The active world, or nil if nothing is open.
active_world :: proc() -> ^World {
    return active_view != nil ? active_view.world : nil
}

// Makes `w` the active world (e.g. the user selected in a panel pinned to it) by activating its
// first view. No-op if it's already active.
world_activate :: proc(w: ^World) {
    if active_world() == w do return
    for v in views do if v.world == w { active_view = v; return }
}

// Closes every open world/view (the GPU must already be idle) and frees the registry.
world_registry_shutdown :: proc() {
    for v in views  do view_request_close(v)
    for w in worlds do world_request_close(w)
    world_registry_process_pending()
    delete(worlds)
    delete(views)
    delete(pending_close_views)
    delete(pending_close_worlds)
}

// ============================ Open ============================

// Opens a scene file as a new world with its own view. Editable and saveable back to `path`.
world_open_scene :: proc(path: string) -> ^World {
    w := new(World, app.allocators.perm)
    world_init(w)
    w.title     = strings.clone(filepath.base(path), app.allocators.perm)
    w.save_path = strings.clone(path, app.allocators.perm)
    w.source    = w.save_path
    scene_load(w, path)
    world_register(w)
    return w
}

// Writes a scene world back to the .level it was opened from. Kits and play worlds (no save_path) can't
// be saved: the running game's state is never written.
world_save :: proc(w: ^World) -> bool {
    if w.save_path == "" || !scene_save(w, w.save_path) do return false
    w.saved_state_id = w.state_id
    return true
}

// Opens a kit (glTF) as a new world with its own view: one entity per mesh node of the glTF's
// scene, where the DCC placed it. Editable, but has no save_path — a kit can't be written back
// to its glTF.
world_open_kit :: proc(kit: ^Kit) -> ^World {
    w := new(World, app.allocators.perm)
    world_init(w)
    w.title = strings.clone(filepath.base(kit.path), app.allocators.perm)
    w.source = strings.clone(kit.path, app.allocators.perm)
    for n in kit.nodes do world_add(w, n.name, n.model, n.position)
    world_register(w)
    return w
}

// Adds another view onto `w` (several viewports on one scene). The world's draw data is shared;
// the new view only adds a camera, a target and its frame constants.
view_open :: proc(w: ^World) -> ^Render_View {
    v := new(Render_View, app.allocators.perm)
    render_view_create(v, w, camera_frame_world(w), 640, 480)
    v.id   = next_view_id
    v.open = true
    next_view_id += 1
    append(&views, v)
    return v
}

@(private="file")
world_register :: proc(w: ^World) {
    world_render_create(w)
    append(&worlds, w)
    ui_host_open(view_open(w))   // its own window: viewport + an entity list and inspector locked to it
}

// ============================ Close ============================

// Ask to close a view; it happens at the top of the next UI frame. Closing a world's last view
// closes the world too.
view_request_close :: proc(v: ^Render_View) {
    if !slice.contains(pending_close_views[:], v) do append(&pending_close_views, v)
}

// Ask to close a world and all its views; happens at the top of the next UI frame.
world_request_close :: proc(w: ^World) {
    if !slice.contains(pending_close_worlds[:], w) do append(&pending_close_worlds, w)
}

// Executes queued closes. Called before the UI builds its frame, so nothing about to be drawn
// references a destroyed target; waits for the GPU so nothing in flight does either.
world_registry_process_pending :: proc() {
    if len(pending_close_views) == 0 && len(pending_close_worlds) == 0 do return
    renderer_dx_wait_idle()

    // Closing something that's playing stops it first (world_play.odin), so its views are back on the
    // level before anything below looks at them: a closing view of a play world, a closing level, or a
    // play world closed directly. Stopping queues the play world, which this loop then passes over.
    for v in pending_close_views do if v.world.play_source != nil do world_stop(v.world)
    for i := 0; i < len(pending_close_worlds); i += 1 {
        w := pending_close_worlds[i]
        if w.play_world != nil || w.play_source != nil do world_stop(w)
    }

    // A closing world takes all its views with it.
    for w in pending_close_worlds {
        for v in views do if v.world == w do view_request_close(v)
    }

    for v in pending_close_views {
        w := v.world
        if active_view == v do active_view = nil   // re-picked below from whatever stays open
        ui_forget_view(v)          // its world window + the panels docked in it
        render_view_destroy(v)
        if i, found := slice.linear_search(views[:], v); found do ordered_remove(&views, i)
        free(v, app.allocators.perm)

        // Last view of an opened world gone → the world goes too.
        still_viewed := false
        for other in views do if other.world == w { still_viewed = true; break }
        if !still_viewed do world_request_close(w)
    }
    clear(&pending_close_views)

    for w in pending_close_worlds {
        if i, found := slice.linear_search(worlds[:], w); found do ordered_remove(&worlds, i)
        lua_world_script_unload(w)
        sound_world_stop(w)
        physics_world_stop(w)
        undo_forget_world(w)       // no undo entry or pinned panel may outlive its world
        ui_forget_world(w)
        world_render_destroy(w)
        world_shutdown(w)
        delete(w.title, app.allocators.perm)
        if w.save_path != "" do delete(w.save_path, app.allocators.perm)
        if w.save_path == "" do delete(w.source, app.allocators.perm)   // a scene's source is its save_path
        free(w, app.allocators.perm)
    }
    clear(&pending_close_worlds)

    if active_view == nil && len(views) > 0 do active_view = views[0]   // the active view closed: fall back to any open one
}

// The open world opened from `path` (scene or kit), if any.
world_find_open :: proc(path: string) -> ^World {
    for w in worlds do if w.source == path do return w
    return nil
}
