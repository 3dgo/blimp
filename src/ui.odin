package blimp

import "core:mem"
import "core:os"
import "vendor:sdl3"
import im "lib:odin-imgui"
import im_sdl3 "lib:odin-imgui/imgui_impl_sdl3"
import im_dx12 "lib:odin-imgui/imgui_impl_dx12"
import "dx"

UI :: struct {
    io: ^im.IO,

    show_stats: bool,   // F3: the stats overlay (ui_draw_stats)
    show_schema_editor: bool,
    show_worlds: bool,
    show_resources: bool,
    show_shadow_maps: bool,

    build_default_layout: bool,   // true on first launch (no imgui.ini yet)
    main_dockspace: im.ID,        // the dockspace over the main window (DockSpaceOverViewport)
    first_view_placed: bool,      // this session's first world/view window docked into the main window
    schema_status: Edit_Buf,      // last schema editor save/validate/build message

    scene_paths: [dynamic]string,     // scene files listed in the Worlds window (rescanned on Refresh)
    scene_paths_scanned: bool,

    hosts: [dynamic]World_Host,       // world windows: an opened world's viewport + its own list/inspector

    tool: Edit_Tool,                  // viewport tool, shared by every view (toolbar, Q/W)
    snap: Gizmo_Snap,                 // gizmo snapping (toolbar; Ctrl inverts while dragging)
    space: Gizmo_Space,               // gizmo axes: world or the entity's own (toolbar)
    pivot: Gizmo_Pivot,               // rotate/scale about the selection centre (default) or each entity's own pivot
    inspector_editing: bool,          // an inspector edit's undo step is open (ui_entity_inspector_body)
    maximized: ^Render_View,          // F11: this view fills the main window (ui_draw_views); nil = none
    maximize_focus: bool,             // bring the maximized view to the front on its first frame
    game: ^Render_View,               // game mode: this view is the whole window as the game, the editor hidden (ui_game.odin); nil = the editor
    show_game_settings: bool,
    font_bold: ^im.Font,              // the UI font in bold (the default font is regular)
}
ui: UI

ui_init :: proc() {
    loc_verify()   // fail loudly on any half-translated UI string

    im.CHECKVERSION()
    im.CreateContext()
    ui.io = im.GetIO()
    ui_saved_state_init()   // before the first NewFrame reads imgui.ini
    ui.io.ConfigFlags = {.NavEnableKeyboard, .NavEnableGamepad, .DockingEnable, .ViewportsEnable}
    ui.io.ConfigWindowsMoveFromTitleBarOnly = true   // body drags belong to the content (orbit, pan, gizmo)
    // A window dragged outside the main window becomes its own OS window: parent it to the main window
    // so clicking the main window can't bury it, while other apps can still cover it.
    ui.io.ConfigViewportsNoDefaultParent = false
    ui.snap = GIZMO_SNAP_DEFAULT

    // First launch (no saved layout on disk) → build the default dock layout in code.
    // Once imgui.ini exists, ImGui loads the user's layout and we leave it alone.
    ui.build_default_layout = ui.io.IniFilename == nil || !os.exists(string(ui.io.IniFilename))

    ui_apply_theme(app.display_scale)   // VS Code-style dark theme (ui_theme.odin)

    im_sdl3.InitForD3D(app.window)

    init_info := im_dx12.InitInfo {
        Device = renderer_dx.render_context.device,
        CommandQueue = renderer_dx.cmd_queue_gfx.handle,
        NumFramesInFlight = 2,
        RTVFormat = renderer_dx.swapchain.format,
        DSVFormat = renderer_dx.swapchain.depth_format,
        SrvDescriptorHeap = renderer_dx.ui_heap.handle,
        SrvDescriptorAllocFn = renderer_dx_ui_srv_alloc,
        SrvDescriptorFreeFn = renderer_dx_ui_srv_free,
    }
    im_dx12.Init(&init_info)

    // Fonts
    font_size := ui_font_size()
    fonts := ui.io.Fonts
    font_config := im.FontConfig{
        FontDataOwnedByAtlas = true,
        RasterizerMultiply = 1.0,
        RasterizerDensity = 1.0,
        ExtraSizeScale = 1.0,
        GlyphMaxAdvanceX = max(f32),
        OversampleH = 2,
        OversampleV = 1,
        SizePixels = font_size,
    }
    // The first font added is the default. Bold is the same stack in bold (dynamic fonts rasterize glyphs
    // as they're drawn, so a second CJK face costs nothing until used): PushFont(ui.font_bold, 0).
    ui_add_font(fonts, "assets_engine/fonts/Roboto-Regular.ttf", "assets_engine/fonts/NotoSansSC-Regular.ttf", font_config)
    ui.font_bold = ui_add_font(fonts, "assets_engine/fonts/Roboto-Bold.ttf", "assets_engine/fonts/NotoSansSC-Bold.ttf", font_config)

    // Open on first launch; after that imgui.ini remembers which windows were open (ui_saved_state.odin).
    ui.show_worlds = true      // open a scene or kit from it
}

// One UI font: Latin, with the editor icons and Chinese merged in.
@(private="file")
ui_add_font :: proc(fonts: ^im.FontAtlas, latin, cjk: cstring, config: im.FontConfig) -> ^im.Font {
    config := config
    font_size := config.SizePixels
    font := im.FontAtlas_AddFontFromFileTTF(fonts, latin, font_size, &config)
    assert(font != nil, "Failed to load the UI font — check working directory")

    merge_config := config
    merge_config.MergeMode = true

    // Icons (editor_icons.odin) merged next, so ICON_* codepoints render inline in any label. Slightly larger
    // than the text, fixed-width so icon buttons line up, and nudged down to sit on the text's centre.
    icon_config := merge_config
    icon_config.ExtraSizeScale = 1.2
    icon_config.GlyphMinAdvanceX = font_size * 1.2
    icon_config.GlyphOffset = {0, font_size * 0.2}
    im.FontAtlas_AddFontFromFileTTF(fonts, ICON_FONT_PATH, font_size, &icon_config)

    merge_config.ExtraSizeScale = 1.35  // CJK reads smaller than Latin at the same point size; enlarge the merged glyphs
    im.FontAtlas_AddFontFromFileTTF(fonts, cjk, font_size, &merge_config)
    return font
}

UI_FONT_SIZE :: 16   // points at display scale 1: the body text; titles and labels scale from it
UI_LABEL_GAP :: 16   // pixels (× display scale) between a form's label column and its inputs

ui_font_size :: proc() -> f32 { return UI_FONT_SIZE * app.display_scale }

// Where a form's inputs start: past its widest label, plus the gap. Measured per form, so rows line up in
// either language (ZH labels are wider).
ui_label_column :: proc(labels: []Loc_ID) -> (x: f32) {
    for id in labels do x = max(x, im.CalcTextSize(tr(id)).x)
    return x + UI_LABEL_GAP * app.display_scale
}

// A window showing one world's settings (World Settings, Bake): which world, and whether an
// edit's undo step is open. Each window keeps one; these procs are the whole protocol.
Settings_Window :: struct {
    world:   ^World,   // whose settings are shown; nil = window closed
    editing: bool,     // an edit's undo step is open (closed once no widget is active)
}

settings_window_toggle :: proc(win: ^Settings_Window, w: ^World) {
    win.world = win.world == w ? nil : w
}

settings_window_open_for :: proc(win: ^Settings_Window, w: ^World) -> bool { return win.world == w }

// The views switched worlds (Play / Stop): a window following the shown world switches with them.
settings_window_retarget :: proc(win: ^Settings_Window, from, to: ^World) {
    if win.world == from do win.world = to
}

settings_window_forget :: proc(win: ^Settings_Window, w: ^World) {
    if win.world == w do win^ = {}
}

// Call after drawing the settings widgets, with the settings as they were before them. Undo is detected
// after the fact (as in the entity inspector): the first changed frame opens one step holding `before`,
// and it stays open while a widget is held, so a whole drag is one Ctrl+Z. A play world records nothing.
settings_window_track_edit :: proc(win: ^Settings_Window, before: World_Settings) {
    before := before
    if mem.compare_ptrs(&before, &win.world.settings, size_of(World_Settings)) != 0 && !win.editing {
        undo_push_settings_edited(win.world, before)
        win.editing = true
    }
    if !im.IsAnyItemActive() do win.editing = false
}

// Views switched from one world to another (Play / Stop, app_lifecycle.odin). UI state pinned to the old
// world follows, and drags in progress on those views end: they were editing the world being left.
ui_retarget_world :: proc(from, to: ^World) {
    ui_entity_rename_forget(from)
    ui_world_settings_retarget(from, to)
    ui_context_menu_forget(from, nil)
    for v in views do if v.world == to {
        ev := editor_view(v)
        ev.gizmo.drag, ev.gizmo.pushed = .None, false
        ev.marquee = {}
    }
}

// A world is closing (app_process_closes): every window that points at it lets go.
ui_forget_world :: proc(w: ^World) {
    ui_entity_rename_forget(w)
    ui_world_settings_forget(w)
    ui_bake_forget(w)
    ui_context_menu_forget(w, nil)
    ui_unsaved_forget_world(w)
}

ui_process_event :: proc(event: ^sdl3.Event) {
    im_sdl3.ProcessEvent(event)
}

ui_update :: proc() {
    if ui.game != nil && ui.game.world.play_source == nil do ui.game = nil   // stopped: back to the editor

    im_dx12.NewFrame()
    im_sdl3.NewFrame()
    im.NewFrame()

    if ui.game != nil {
        ui_draw_game()   // instead of the whole editor
        im.Render()
        return
    }

    dockspace_id := im.DockSpaceOverViewport(0, im.GetMainViewport())
    ui.main_dockspace = dockspace_id
    if ui.build_default_layout {
        ui.build_default_layout = false
        ui_build_default_layout(dockspace_id)
    }

    if(im.BeginMainMenuBar()) {
        if menu_begin(tr(.Menu_Show)) {
            im.MenuItemBoolPtr(tr(.Menu_Worlds), nil, &ui.show_worlds)
            menu_section(tr(.Menu_Section_Project))
            im.MenuItemBoolPtr(tr(.Menu_Schema_Editor), nil, &ui.show_schema_editor)
            im.MenuItemBoolPtr(tr(.Menu_Game_Settings), nil, &ui.show_game_settings)
            menu_section(tr(.Menu_Section_Profile))
            im.MenuItemBoolPtr(tr(.Menu_Resources), nil, &ui.show_resources)
            im.MenuItemBoolPtr(tr(.Menu_Shadow_Maps), nil, &ui.show_shadow_maps)
            menu_end()
        }
        if menu_begin(tr(.Menu_Language)) {
            // Language names are shown in their own script regardless of current language.
            if im.MenuItem("English", nil, loc_lang == .EN) do loc_lang = .EN
            if im.MenuItem("简体中文", nil, loc_lang == .ZH) do loc_lang = .ZH
            menu_end()
        }
        im.EndMainMenuBar()
    }

    ui_handle_shortcuts()

    ui_draw_views()

    if ui.show_worlds {
        ui_draw_worlds()
    }

    for &h in ui.hosts do ui_draw_entity_panels(&h)
    ui_draw_world_settings()
    ui_draw_bake()
    ui_draw_game_settings()
    ui_draw_unsaved_prompt()   // the modal, if a close or quit is waiting on Save / Don't Save / Cancel

    if ui.show_schema_editor {
        ui_draw_schema_editor()
    }

    if ui.show_resources {
        ui_draw_resources()
    }

    if ui.show_shadow_maps {
        ui_draw_shadow_maps()
    }

    if ui.show_stats {
        ui_draw_stats()
    }
    ui_draw_log_overlay()   // recent errors and warnings (debug builds)

    ui_saved_state_update()

    im.Render()
}

MENU_SECTION_SCALE :: 0.8   // section headers inside a menu, × the UI font size
MENU_ROW_SPACING   :: 2.0   // vertical item spacing inside a menu, × style.ItemSpacing.y

// Menus are laid out like Unreal's: roomier rows, items indented under flush-left section headers.
// Pair with menu_end.
@(private="file")
menu_begin :: proc(label: cstring) -> bool {
    if !im.BeginMenu(label) do return false
    style := im.GetStyle()
    im.PushStyleVarImVec2(.ItemSpacing, {style.ItemSpacing.x, style.ItemSpacing.y * MENU_ROW_SPACING})
    im.Indent()
    return true
}

@(private="file")
menu_end :: proc() {
    im.Unindent()
    im.PopStyleVar()
    im.EndMenu()
}

// A section header inside a menu_begin menu: smaller dimmed text at the left edge, then a faint line
// to the right, with extra room above so it reads as a heading rather than an item.
@(private="file")
menu_section :: proc(label: cstring) {
    style := im.GetStyle()
    line_col := style.Colors[im.Col.TextDisabled]
    line_col.w = 0.35
    im.Unindent()
    im.Dummy({0, style.ItemSpacing.y * 0.5})
    im.PushFontFloat(nil, ui_font_size() * MENU_SECTION_SCALE)
    im.PushStyleColorImVec4(.Text, style.Colors[im.Col.TextDisabled])
    im.PushStyleColorImVec4(.Separator, line_col)
    im.PushStyleVarImVec2(.SeparatorTextPadding, {0, 0})
    im.SeparatorText(label)
    im.PopStyleVar()
    im.PopStyleColor(2)
    im.PopFont()
    im.Indent()
}

// Builds the default editor dock layout — [ Worlds | world windows ] — on first launch only;
// ImGui's saved imgui.ini takes over afterwards. Reuses the node DockSpaceOverViewport already made
// (RemoveNodeChildNodes keeps it a dockspace, so we avoid the private DockSpace flag). Windows dock
// by their current label; the ### id in each keeps the assignment stable across language switches.
ui_build_default_layout :: proc(dockspace_id: im.ID) {
    im.DockBuilderRemoveNodeChildNodes(dockspace_id)
    im.DockBuilderSetNodeSize(dockspace_id, im.GetMainViewport().Size)

    right := dockspace_id
    left: im.ID
    im.DockBuilderSplitNode(right, .Left, 0.2, &left, &right)   // Worlds on the left, world windows fill the rest
    im.DockBuilderDockWindow(tr(.Win_Worlds), left)
    im.DockBuilderFinish(dockspace_id)
}

ui_render_platform_windows :: proc() {
    if .ViewportsEnable in ui.io.ConfigFlags {
        im.UpdatePlatformWindows()
        im.RenderPlatformWindowsDefault()
    }
}

// ImGui's draw data into the bound backbuffer (between renderer_dx_draw_frame and renderer_dx_submit).
ui_draw :: proc() {
    dx.descriptor_heap_bind(renderer_dx.cmd_gfx, {renderer_dx.ui_heap, renderer_dx.sampler_heap})
    im_dx12.RenderDrawData(im.GetDrawData(), renderer_dx.cmd_gfx.handle)
}

ui_shutdown :: proc() {
    for p in ui.scene_paths do delete(p, app.allocators.perm)
    delete(ui.scene_paths)
    delete(ui.hosts)
    editor_views_shutdown()
    editor_worlds_shutdown()

    im_dx12.Shutdown()
    im_sdl3.Shutdown()
    im.DestroyContext()
}
