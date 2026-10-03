package blimp

// The editor's side of a Render_View: where its image sits on screen, mouse interaction in it (camera
// navigation in editor_camera.odin, gizmo, marquee), and window placement. Kept off Render_View so the
// renderer's view stays a target + camera + world. One per view, created on first use, freed when the
// view closes (editor_view_forget from ui_forget_view).
Editor_View :: struct {
    view: ^Render_View,

    // The view's image this frame, in ImGui screen coordinates (set by ui_draw_view). Keyboard
    // actions (paste, remote picks) raycast through it even though they run before that draw.
    screen_min, screen_size: vec2,
    hovered: bool,

    nav:     Editor_Nav,    // mouse/keyboard camera navigation (editor_camera.odin)
    context_click: bool,    // this frame: RMB released without flying = a right-click (opens the context menu); set by editor_navigate
    remote_context: Maybe(vec2),   // a right-click at this view pixel requested by blimpctl `menu`
    gizmo:   Gizmo_State,   // transform gizmo hover/drag (editor_gizmo.odin)
    marquee: struct { pressing, dragging, double: bool, start: vec2 },   // left-press selection in progress (ui_view_selection); double: the press was a double-click
    window_open: bool,      // its window's open flag: the user closing the window closes the view
    placed:  bool,          // its window got its first-frame floating placement (ui_next_view_window_placement)
    icon_hidden: [MAX_ENTITIES]bool,   // camera/light icon blocked by geometry, by handle index (editor_icons_update_occlusion)
    icon_cursor: int,                  // where the next frame's icon occlusion rays start
    game_view: bool,                   // G: hide everything editor-only here (icons, outlines, selection boxes, gizmo), like Unreal
    show_probes: bool,                 // draw the world's baked probes as debug spokes (probe_grid_debug_lines)
    collapsed: bool,        // its window was collapsed last frame
    full_size: vec2,        // its window's size while expanded, restored after a collapse (ui_view_window_keep_size)
    restore_frames: int,    // frames left to keep reapplying full_size after an expand
}

@(private="file")
editor_views: [dynamic]^Editor_View   // editor state → general heap; individually allocated, so pointers stay put

// The editor state for `v`, created on first use.
editor_view :: proc(v: ^Render_View) -> ^Editor_View {
    for ev in editor_views do if ev.view == v do return ev
    ev := new(Editor_View)
    ev.view = v
    ev.window_open = true
    ev.nav.fly_speed = NAV_FLY_SPEED
    append(&editor_views, ev)
    return ev
}

editor_view_forget :: proc(v: ^Render_View) {
    for ev, i in editor_views {
        if ev.view != v do continue
        delete(ev.gizmo.members)
        free(ev)
        unordered_remove(&editor_views, i)
        return
    }
}

editor_views_shutdown :: proc() {
    for ev in editor_views { delete(ev.gizmo.members); free(ev) }
    delete(editor_views)
}

// The view to act in for world `w` (a level or its play copy) from outside any viewport — the entity
// list, the Bake window: the active view when it shows that level, else the first that does. nil if none.
editor_view_for_world :: proc(w: ^World) -> ^Editor_View {
    level := world_level(w)
    if active_view != nil && world_level(active_view.world) == level do return editor_view(active_view)
    for v in views do if world_level(v.world) == level do return editor_view(v)
    return nil
}
