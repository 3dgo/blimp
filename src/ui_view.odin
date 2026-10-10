package blimp

import "core:fmt"
import "core:math"
import "core:math/linalg"
import hm "core:container/handle_map"
import im "lib:odin-imgui"
import "dx"

// An opened scene/kit gets one window holding its own little dockspace: the viewport on the left,
// an entity list and inspector locked to that world stacked on the right. AutoHideTabBar hides the
// label of every node that holds a single window, so it reads as one panel. The host window carries
// the title and the close button; closing it closes the view (and the world, if it was the last one).
World_Host :: struct {
    view:        ^Render_View,
    built:       bool,   // dock layout applied (done on the first frame the window is visible)
    show_panels: bool,   // the entity list and inspector (the toolbar's panels button); hidden, the viewport fills the window
    // The panels' search boxes (NUL-terminated): entity names in the list, fields in the inspector.
    list_search:      [64]u8,
    inspector_search: [64]u8,
}

ui_host_open :: proc(v: ^Render_View) {
    append(&ui.hosts, World_Host{view = v, show_panels = true})
}

ui_host_find :: proc(v: ^Render_View) -> ^World_Host {
    for &h in ui.hosts do if h.view == v do return &h
    return nil
}

// F11 / the toolbar button: `v` fills the main window, or goes back to its window.
ui_maximize_toggle :: proc(v: ^Render_View) {
    ui.maximized = ui.maximized == v ? nil : v
    ui.maximize_focus = ui.maximized != nil
}

// G / the toolbar button: hide everything editor-only in `v` (Unreal's game view): icons, outlines,
// selection boxes and the gizmo. A gizmo drag in progress ends where it is.
ui_game_view_toggle :: proc(v: ^Render_View) {
    ev := editor_view(v)
    ev.game_view = !ev.game_view
    ev.gizmo.drag, ev.gizmo.hot = .None, .None
}

// A view is closing: its world window and the panels docked in it go with it.
ui_forget_view :: proc(v: ^Render_View) {
    if ui.maximized == v do ui.maximized = nil
    if ui.game == v do ui.game = nil
    editor_view_forget(v)
    ui_context_menu_forget(nil, v)
    for i := len(ui.hosts) - 1; i >= 0; i -= 1 do if ui.hosts[i].view == v do ordered_remove(&ui.hosts, i)
}

// One window per view. A view opened with its world is a world window (viewport + its own list and
// inspector); a "New Viewport" view is a plain window. Every one is labelled "<world title> 视口",
// with ● on the active one (what Ctrl+C/V act on); closing it closes the view.
ui_draw_views :: proc() {
    for v in views {
        mark  := v == active_view ? "● " : ""
        play  := v.world.play_source == nil ? "" : v.world.paused ? ICON_PAUSE + " " : ICON_PLAY + " "   // showing the game
        level := world_level(v.world)
        title := fmt.ctprintf("%s%s%s%s %s", mark, play, level.title, world_dirty(level) ? "*" : "", tr(.View_Suffix))   // * = unsaved changes

        h := ui_host_find(v)
        if v == ui.maximized {
            // F11: the view fills the main window instead. A world window's host still runs underneath,
            // hidden behind it, so its docked panels and layout survive; a plain view's window just waits.
            if h != nil do ui_draw_host(h, title)
            mv := im.GetMainViewport()
            im.SetNextWindowPos(mv.WorkPos)
            im.SetNextWindowSize(mv.WorkSize)
            im.SetNextWindowViewport(mv.ID_)
            if ui.maximize_focus do im.SetNextWindowFocus()   // on top when it opens; other windows can still come forward
            ui.maximize_focus = false
            ui_draw_view(v, "###maximized_view", nil, im.WindowFlags_NoDecoration + {.NoDocking, .NoMove, .NoSavedSettings})
        } else if h != nil {
            // World window: the host carries title + close; the viewport docks inside it, untitled.
            if ui_draw_host(h, title) do ui_draw_view(v, fmt.ctprintf("###view%d", v.id), nil)
        } else {
            ui_next_view_window_placement(v)
            ui_draw_view(v, fmt.ctprintf("%s###view%d", title, v.id), &editor_view(v).window_open, {.NoCollapse})
        }
        if !editor_view(v).window_open do ui_request_close_view(v)   // asks first if it's the last view of an unsaved world
    }
}

VIEW_WINDOW_SHARE    :: 0.8                 // first-open size of a floating view/world window, as a share of the main window
VIEW_WINDOW_MIN_SIZE :: [2]f32{320, 180}   // floating view/world windows can't be shrunk below this
HOST_PANEL_WIDTH     :: 380                 // a world window's list/inspector column, at its first layout (then the user's)

VIEW_WINDOW_CASCADE  :: 30                  // per-window offset so several new windows don't stack exactly

// A newly opened world window (or extra viewport) is placed on its first frame only, overriding
// whatever imgui.ini remembers for a reused window id (ids restart every session). The session's first
// one docks into the main window's central node; later ones float, centred on the main window and
// cascaded, at the default size. After that it's the user's to dock/move/resize.
ui_next_view_window_placement :: proc(v: ^Render_View) {
    s := app.display_scale
    central := im.DockBuilderGetCentralNode(ui.main_dockspace)
    if ev := editor_view(v); !ev.placed && !ui.first_view_placed && central != nil {
        ev.placed = true
        ui.first_view_placed = true
        im.SetNextWindowDockID(central.ID_, .Always)
    } else if !ev.placed {
        ev.placed = true
        mv     := im.GetMainViewport()
        offset := f32((v.id - 1) % 8) * VIEW_WINDOW_CASCADE * s
        im.SetNextWindowDockID(0, .Always)   // undocked
        im.SetNextWindowViewport(mv.ID_)     // in the main window, even if imgui.ini remembers this id as its own OS window
        im.SetNextWindowPos({mv.Pos.x + mv.Size.x * 0.5 + offset, mv.Pos.y + mv.Size.y * 0.5 + offset}, .Always, {0.5, 0.5})
        im.SetNextWindowSize(mv.WorkSize * VIEW_WINDOW_SHARE, .Always)
    }
    im.SetNextWindowSizeConstraints({VIEW_WINDOW_MIN_SIZE.x * s, VIEW_WINDOW_MIN_SIZE.y * s}, {max(f32), max(f32)})
}

// Draws a world window: a host holding a dockspace with [ viewport | list / inspector ]. Builds that
// layout the first frame it's visible. Returns true once built, i.e. its docked windows may be drawn.
// View windows don't collapse (.NoCollapse); while hidden as a background tab the dockspace is kept alive so nothing undocks.
ui_draw_host :: proc(h: ^World_Host, title: cstring) -> bool {
    v := h.view
    ui_next_view_window_placement(v)

    im.PushStyleVarImVec2(im.StyleVar.WindowPadding, {0, 0})
    visible := im.Begin(fmt.ctprintf("%s###host%d", title, v.id), &editor_view(v).window_open, {.NoCollapse})
    im.PopStyleVar()

    dockspace_id := im.GetID("dock")
    if !visible {
        im.DockSpace(dockspace_id, {0, 0}, {.KeepAliveOnly})
    } else {
        im.DockSpace(dockspace_id, {0, 0}, {.AutoHideTabBar})
        if !h.built {
            // Same technique as ui_build_default_layout: reuse the node DockSpace just made. The column gets
            // HOST_PANEL_WIDTH in pixels, not a share of the window: on this first frame the window may not have
            // its docked size yet, and the viewport (the central node) is what grows with it afterwards, so a
            // share of a too-small window stayed narrow. Sized against the main window when it's that small (or has
            // no height yet, as when docked from a saved imgui.ini: DockBuilderSetNodeSize asserts on 0).
            im.DockBuilderRemoveNodeChildNodes(dockspace_id)
            s := app.display_scale
            size := im.GetContentRegionAvail()
            if size.x < 2 * HOST_PANEL_WIDTH * s || size.y < 1 do size = im.GetMainViewport().WorkSize
            im.DockBuilderSetNodeSize(dockspace_id, size)
            left := dockspace_id
            right, list, inspector: im.ID
            im.DockBuilderSplitNode(left, .Right, clamp(HOST_PANEL_WIDTH * s / size.x, 0.1, 0.5), &right, &left)
            im.DockBuilderSplitNode(right, .Down, 0.5, &inspector, &list)
            im.DockBuilderDockWindow(fmt.ctprintf("###view%d", v.id), left)
            im.DockBuilderDockWindow(fmt.ctprintf("###entity_list%d", v.id), list)
            im.DockBuilderDockWindow(fmt.ctprintf("###entity_inspector%d", v.id), inspector)
            im.DockBuilderFinish(dockspace_id)
            h.built = true
        }
    }
    im.End()
    return h.built
}

ui_draw_view :: proc(view: ^Render_View, label: cstring, p_open: ^bool, extra_flags: im.WindowFlags = {}) {
    im.PushStyleVarImVec2(im.StyleVar.WindowPadding, {0, 0})
    visible := im.Begin(label, p_open, {.NoScrollbar, .NoScrollWithMouse} + extra_flags)   // the wheel zooms the camera
    if visible {

        ui_view_toolbar(view)
        ui_view_tools()   // a column down the left, the image beside it
        im.SameLine()
        ui_view_image(view)

        // Refresh the editor's copy of this view's screen rect each frame so keyboard actions
        // (paste) can raycast through the cursor even though they run before this draw.
        ev := editor_view(view)
        img_min, img_max := im.GetItemRectMin(), im.GetItemRectMax()
        ev.screen_min  = {img_min.x, img_min.y}
        ev.screen_size = {f32(view.target.width), f32(view.target.height)}
        ev.hovered     = im.IsItemHovered()
        if !ev.game_view do editor_draw_icons(ev)   // camera / light icons, under the gizmo (editor_shapes.odin)
        if !ev.game_view do ui_bake_probe_highlight(ev)   // the probe hovered in the Bake window's atlas (ui_bake.odin)

        if im.IsWindowFocused() do view_activate(view)   // focusing a viewport makes its world active
        editor_navigate(ev)
        gizmo_owns_mouse := !ev.game_view && gizmo_update(ev, ui.tool, ui.space, ui.pivot, ui.snap)   // G hides (and disables) it

        ui_view_selection(ev, gizmo_owns_mouse)

        // Showing the game: a border in the play colour (amber while paused), so play edits read as such.
        if view.world.play_source != nil {
            col: [4]f32 = view.world.paused ? {0.9, 0.62, 0.2, 1} : im.GetStyleColorVec4(.ButtonActive)^
            im.DrawList_AddRect(im.GetWindowDrawList(), img_min, img_max, im.GetColorU32ImVec4(col), 0, 2 * app.display_scale)
        }
        ui_view_game_ui(view, img_min, img_max)   // the script's screen UI (World.ui); after the reads of the image item above

        // Right-click (RMB released without flying): select what's under the cursor unless it's already
        // selected (so the menu acts on it), then open the menu, pasting at the click's raycast.
        // `remote_context` is the same click at a view pixel, from blimpctl's `menu`.
        if ev.context_click || ev.remote_context != nil {
            w := view.world
            mp := im.GetMousePos()
            p := vec2{mp.x, mp.y} - ev.screen_min
            if rp, ok := ev.remote_context.?; ok do p = rp
            ev.remote_context = nil
            if target, ok := view_pick(ev, ev.screen_min + p); ok && !selection_has(w, target.entity) do selection_only(w, target.entity)
            im.SetNextWindowPos(ev.screen_min + p)   // at the click (the mouse, unless it came from remote)
            ui_context_menu_open(w, view, view_paste_point(ev, ev.screen_min + p))
        }
        ui_context_menu()
    }
    im.End()
    im.PopStyleVar()
}

// The view's image, filling the rest of the window: the target follows the space it's given.
ui_view_image :: proc(view: ^Render_View) {
    avail := im.GetContentRegionAvail()
    size := uvec2{u32(max(avail.x, 1)), u32(max(avail.y, 1))}
    if render_view_needs_rebuild(view, size) {   // new size, or the world's background colour changed
        view.target.clear_color = render_view_clear_color(view.world)
        renderer_dx_resize_view(view, size)
    }
    gpu := dx.descriptor_heap_gpu_handle_at(renderer_dx.ui_heap, view.target.srv.heap_slot)
    im.Image(im.TextureRef{_TexID = im.TextureID(gpu.ptr)}, avail)
}

// Where a keyboard paste lands in ev's view: under the mouse, or under the view's centre if the cursor
// isn't over it (view_paste_point).
paste_target_point :: proc(ev: ^Editor_View) -> vec3 {
    if ev.screen_size.x <= 0 || ev.screen_size.y <= 0 do return ev.view.camera.pivot
    p := ev.screen_min + ev.screen_size * 0.5
    if ev.hovered {
        mp := im.GetMousePos()
        p = {mp.x, mp.y}
    }
    return view_paste_point(ev, p)
}

MARQUEE_DRAG_PX :: 4   // a press that moves further than this is a marquee, not a click

// Viewport selection, 3ds Max-style marquee with Unity's Ctrl: a left press that isn't on the gizmo
// (and isn't Alt = orbit) becomes a click on release, or a marquee once dragged past a few pixels.
// Click: select what's under the cursor (nothing: clear). Marquee: select every entity whose box
// touches the rectangle (crossing). Ctrl at release: toggle those instead of replacing.
@(private="file")
ui_view_selection :: proc(ev: ^Editor_View, gizmo_owns_mouse: bool) {
    m := &ev.marquee
    mp := im.GetMousePos()
    mouse := vec2{mp.x, mp.y}
    if ev.hovered && im.IsMouseClicked(.Left) && !ui.io.KeyAlt && !gizmo_owns_mouse && ev.nav.drag == .None {
        m.pressing, m.dragging, m.start = true, false, mouse
        m.double = im.IsMouseDoubleClicked(.Left)
    }
    if !m.pressing do return

    if !m.dragging && linalg.length(mouse - m.start) > MARQUEE_DRAG_PX * app.display_scale do m.dragging = true
    lo, hi := linalg.min(m.start, mouse), linalg.max(m.start, mouse)

    if im.IsMouseDown(.Left) {
        if m.dragging {
            dl := im.GetWindowDrawList()
            im.DrawList_PushClipRect(dl, ev.screen_min, ev.screen_min + ev.screen_size, true)
            im.DrawList_AddRectFilled(dl, lo, hi, im.ColorConvertFloat4ToU32({1, 1, 1, 0.06}))
            im.DrawList_AddRect(dl, lo, hi, im.ColorConvertFloat4ToU32({1, 1, 1, 0.8}), 0, 1)
            im.DrawList_PopClipRect(dl)
        }
        return
    }

    // Released.
    m.pressing = false
    w := ev.view.world
    world_activate(w)
    op := selection_op_from_modifiers(ui.io.KeyCtrl, ui.io.KeyShift)
    if m.dragging do selection_marquee(ev, lo, hi, op)
    else          do selection_click(ev, m.start, op)
    // A plain double-click on an entity frames it (the first click already selected it), like F.
    if !m.dragging && m.double && op == .Replace && selection_count(w) > 0 do editor_frame_selection(ev)
}

// Appends `v`'s editor lines to this frame's debug lines and records its ranges on the view, which the
// renderer then draws into that view only (app_run calls this for every view before rendering). Tested
// against the scene's depth: the world's game lines (World.debug_line, even in the game view), then the
// editor's: baked probes, the manual bake box, camera/light shapes, and the selection boxes — the active
// entity pale green, the rest of the selection green. On top of everything: the collision view's shapes.
ui_view_debug_lines :: proc(v: ^Render_View) {
    editor_lines := !editor_view(v).game_view && v != ui.game   // G or game mode: none of the editor's lines in this view
    v.debug_first = u32(len(debug_draw.verts))
    for l in v.world.debug_lines do debug_line(l.a, l.b, l.color)   // the game's own lines, in every view, game view too
    if editor_lines {
        if editor_view(v).show_probes {
            g := &world_lighting(v.world).probes   // a play copy shows its level's, lit by its own group scales
            probe_grid_debug_lines(g, probe_layer_scales(g, light_group_scales(v.world)), math.pow(2, v.world.settings.exposure))
        }
        ui_bake_bounds_lines(world_level(v.world))   // the manual bake box while the Bake window is open (ui_bake.odin)

        it := hm.iterator_make(&v.world.entities)
        for e, h in hm.iterate(&it) {
            sel_color := selection_color(v.world, h)
            editor_entity_shapes(e, e.selected ? sel_color : nil)   // camera frustum / light reach (editor_shapes.odin)
            if !e.selected || !entity_drawn(e) do continue          // hidden / disabled: no box either
            selection_draw_bounds(e, sel_color)
        }
    }
    v.debug_count = u32(len(debug_draw.verts)) - v.debug_first

    // Collision last: it's the most lines, so if it fills the buffer the selection still shows.
    v.debug_top_first = u32(len(debug_draw.verts))
    if editor_lines && editor_view(v).show_collision {
        it := hm.iterator_make(&v.world.entities)
        for e, _ in hm.iterate(&it) do editor_collision_lines(e)
    }
    v.debug_top_count = u32(len(debug_draw.verts)) - v.debug_top_first
}
