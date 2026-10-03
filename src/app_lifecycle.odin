package blimp

// Structural changes — opening, playing, stopping and closing worlds and views, and reloading assets —
// touch nearly every layer: the world lists, the renderer's mirrors, physics, sound, the Lua script, undo
// and the UI. Each change is one proc here that calls them in order, so the whole sequence reads top to
// bottom in one place.
//
// This is the one file allowed to call across every layer (CLAUDE.md → Layers). Lower layers never call
// up: world_registry.odin and world_play.odin do only the world part, and the UI, blimpctl and hot reload
// call these procs rather than the parts.

// ============================ Open ============================

// Opens a scene (.level) in its own world window.
app_open_scene :: proc(path: string) -> ^World {
    w := world_open_scene(path)
    app_world_opened(w)
    return w
}

// Opens a kit (glTF) in its own world window.
app_open_kit :: proc(kit: ^Kit) -> ^World {
    w := world_open_kit(kit)
    app_world_opened(w)
    return w
}

// Another viewport onto `w`, framing the whole world. Several viewports on one world share its draw data;
// a view only adds a camera, a target and its frame constants.
app_view_open :: proc(w: ^World) -> ^Render_View {
    v := new(Render_View, app.allocators.perm)
    render_view_create(v, w, camera_frame_world(w), 640, 480)
    view_register(v)
    return v
}

@(private="file")
app_world_opened :: proc(w: ^World) {
    world_render_create(w)
    ui_host_open(app_view_open(w))   // its own window: viewport + an entity list and inspector locked to it
}

// ============================ Play ============================

// Starts playing `w`'s level; returns the play world (already playing: the existing one). Its views
// switch to the copy, and its script loads on the first frame of play (lua_worlds_update).
app_play :: proc(w: ^World) -> ^World {
    level := world_level(w)
    if level.play_world != nil do return level.play_world
    p := world_play_copy(level)
    editor_world_copy(level, p)
    world_render_create(p)
    ui_retarget_world(level, p)
    physics_world_start(p)
    sound_world_start(p)
    return p
}

// Stops `w`'s level playing: the game's runtime state goes now, its views go back to the level, and the
// play world closes next frame.
app_stop :: proc(w: ^World) {
    p := world_level(w).play_world
    if p == nil do return
    app_world_runtime_stop(p)
    level := p.play_source
    world_play_discard(p)
    ui_retarget_world(p, level)
}

// Everything that only runs while a world plays: its script, its voices, its physics. Idempotent: Stop
// and close both call it.
@(private="file")
app_world_runtime_stop :: proc(w: ^World) {
    lua_world_script_unload(w)
    sound_world_stop(w)
    physics_world_stop(w)
}

// ============================ Close ============================

// Executes the closes requested since last frame (view_request_close, world_request_close). Called at the
// start of the frame, before the UI builds draw data that could reference what closes; waits for the
// GPU so nothing in flight does either.
app_process_closes :: proc() {
    if len(pending_close_views) == 0 && len(pending_close_worlds) == 0 do return
    renderer_dx_wait_idle()

    // Closing something that's playing stops it first, so its views are back on the level before anything
    // below looks at them: a closing view of a play world, a closing level, or a play world closed directly.
    // Stopping queues the play world, which the world loop below then closes.
    for v in pending_close_views do if v.world.play_source != nil do app_stop(v.world)
    for i := 0; i < len(pending_close_worlds); i += 1 {
        w := pending_close_worlds[i]
        if w.play_world != nil || w.play_source != nil do app_stop(w)
    }

    // A closing world takes all its views with it.
    for w in pending_close_worlds do for v in views do if v.world == w do view_request_close(v)

    for v in pending_close_views {
        w := v.world
        ui_forget_view(v)   // its world window + the panels docked in it, and its Editor_View
        render_view_destroy(v)
        view_free(v)
        if !world_viewed(w) do world_request_close(w)   // last view of a world gone → the world goes too
    }
    clear(&pending_close_views)

    for w in pending_close_worlds {
        app_world_runtime_stop(w)
        undo_forget_world(w)   // no undo entry or pinned panel may outlive its world
        ui_forget_world(w)
        editor_world_forget(w)
        world_render_destroy(w)
        world_free(w)
    }
    clear(&pending_close_worlds)

    if active_view == nil do view_activate(nil)   // the active view closed: fall back to any open one
}

// Closes every world and view (shutdown; the GPU is already idle).
app_close_all :: proc() {
    for v in views  do view_request_close(v)
    for w in worlds do world_request_close(w)
    app_process_closes()
}

// ============================ Assets ============================

// Throws every asset away and loads them again from disk (debug hot reload, app_hot_reload.odin): the
// asset arena and the GPU copies (asset_buffers). Play worlds' physics is rebuilt around it, since its
// shapes point at the collision data. Entities keep pointing at the same keys (asset_keys), so they pick
// up whatever the files hold now; a key that no longer loads draws nothing, with a warning.
app_reload_assets :: proc() {
    renderer_dx_wait_idle()
    asset_buffers_destroy()
    for w in worlds do if w.play_source != nil do physics_world_stop(w)
    asset_system_reload()
    asset_buffers_create()
    asset_buffers_upload()
    for w in worlds do if w.play_source != nil do physics_world_start(w)
}
