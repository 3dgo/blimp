package blimp

import "core:os"
import "vendor:sdl3"
import im "lib:odin-imgui"
import im_sdl3 "lib:odin-imgui/imgui_impl_sdl3"
import im_dx12 "lib:odin-imgui/imgui_impl_dx12"
import "dx"

UI :: struct {
    io: ^im.IO,

    show_demo_window: bool,
    show_stats: bool,   // F3: the stats overlay (ui_draw_stats)
    show_schema_editor: bool,
    show_worlds: bool,
    show_asset_buffers: bool,

    build_default_layout: bool,   // true on first launch (no imgui.ini yet)
    schema_status: Edit_Buf,      // last schema editor save/validate/build message

    scene_paths: [dynamic]string,     // scene files listed in the Worlds window (rescanned on Refresh)
    scene_paths_scanned: bool,

    panels: [dynamic]Entity_Panel,    // entity lists + inspectors (ui_entity_panels.odin)
    next_panel_id: u32,
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
    show_templates: bool,             // the Templates window (ui_templates.odin)
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
    ui.snap = GIZMO_SNAP_DEFAULT

    // First launch (no saved layout on disk) → build the default dock layout in code.
    // Once imgui.ini exists, ImGui loads the user's layout and we leave it alone.
    ui.build_default_layout = ui.io.IniFilename == nil || !os.exists(string(ui.io.IniFilename))

    ui_apply_theme(app.dispaly_scale)   // VS Code-style dark theme (ui_theme.odin)
    
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
    font_size := 16 * app.dispaly_scale
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
    font := im.FontAtlas_AddFontFromFileTTF(fonts, "assets_engine/fonts/Roboto-Regular.ttf", 
        font_size, &font_config)
    assert(font != nil, "Failed to load Roboto — check working directory")

    merge_config := font_config
    merge_config.MergeMode = true

    // Icons (editor_icons.odin) merged next, so ICON_* codepoints render inline in any label. Slightly larger
    // than the text, fixed-width so icon buttons line up, and nudged down to sit on the text's centre.
    icon_config := merge_config
    icon_config.ExtraSizeScale = 1.2
    icon_config.GlyphMinAdvanceX = font_size * 1.2
    icon_config.GlyphOffset = {0, font_size * 0.2}
    im.FontAtlas_AddFontFromFileTTF(fonts, ICON_FONT_PATH, font_size, &icon_config)

    merge_config.ExtraSizeScale = 1.35  // CJK reads smaller than Latin at the same point size; enlarge the merged glyphs
    im.FontAtlas_AddFontFromFileTTF(fonts, "assets_engine/fonts/NotoSansSC-Regular.ttf",
        font_size, &merge_config)
    
    ui.show_demo_window = false
    // Open on first launch; after that imgui.ini remembers which windows were open (ui_saved_state.odin).
    ui.show_worlds = true      // open a scene or kit from it
    ui.show_templates = true   // docked above Worlds (ui_build_default_layout)
    ui.show_stats = false
}

ui_process_event :: proc(event: ^sdl3.Event) {
    im_sdl3.ProcessEvent(event)
}

ui_update :: proc() {
    // Closes requested last frame happen here, before this frame's draw data can reference them.
    world_registry_process_pending()
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
    if ui.build_default_layout {
        ui.build_default_layout = false
        ui_build_default_layout(dockspace_id)
    }

    if(im.BeginMainMenuBar()) {
        if menu_begin(tr(.Menu_Show)) {
            im.MenuItemBoolPtr(tr(.Menu_Worlds), nil, &ui.show_worlds)
            menu_section(tr(.Menu_Section_Entities))
            // Each opens another floating panel (world windows have their own list and inspector).
            if im.MenuItem(tr(.Menu_Entity_List))      do ui_entity_panel_new(.List)
            if im.MenuItem(tr(.Menu_Entity_Inspector)) do ui_entity_panel_new(.Inspector)
            im.MenuItemBoolPtr(tr(.Menu_Templates), nil, &ui.show_templates)
            menu_section(tr(.Menu_Section_Project))
            im.MenuItemBoolPtr(tr(.Menu_Schema_Editor), nil, &ui.show_schema_editor)
            im.MenuItemBoolPtr(tr(.Menu_Game_Settings), nil, &ui.show_game_settings)
            menu_section(tr(.Menu_Section_Profile))
            im.MenuItemBoolPtr(tr(.Menu_Asset_Buffers), nil, &ui.show_asset_buffers)
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

    ui_draw_entity_panels()
    ui_draw_world_settings()
    ui_draw_game_settings()
    ui_draw_templates()
    ui_draw_unsaved_prompt()   // the modal, if a close or quit is waiting on Save / Don't Save / Cancel

    if ui.show_schema_editor {
        ui_draw_schema_editor()
    }

    if ui.show_asset_buffers {
        ui_draw_asset_buffers()
    }

    if ui.show_stats {
        ui_draw_stats()
    }

    if ui.show_demo_window {
        im.ShowDemoWindow(&ui.show_demo_window)
    }
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
    im.PushFontFloat(nil, 16 * app.dispaly_scale * MENU_SECTION_SCALE)
    im.PushStyleColorImVec4(.Text, style.Colors[im.Col.TextDisabled])
    im.PushStyleColorImVec4(.Separator, line_col)
    im.PushStyleVarImVec2(.SeparatorTextPadding, {0, 0})
    im.SeparatorText(label)
    im.PopStyleVar()
    im.PopStyleColor(2)
    im.PopFont()
    im.Indent()
}

// Builds the default editor dock layout — [ world windows | Worlds ] — on first launch only;
// ImGui's saved imgui.ini takes over afterwards. Reuses the node DockSpaceOverViewport already made
// (RemoveNodeChildNodes keeps it a dockspace, so we avoid the private DockSpace flag). Windows dock
// by their current label; the ### id in each keeps the assignment stable across language switches.
ui_build_default_layout :: proc(dockspace_id: im.ID) {
    im.DockBuilderRemoveNodeChildNodes(dockspace_id)
    im.DockBuilderSetNodeSize(dockspace_id, im.GetMainViewport().Size)

    left := dockspace_id
    right: im.ID
    im.DockBuilderSplitNode(left, .Right, 0.22, &right, &left)   // Worlds on the right, world windows fill the rest
    top: im.ID
    im.DockBuilderSplitNode(right, .Up, 0.3, &top, &right)      // Templates above Worlds

    im.DockBuilderDockWindow(tr(.Win_Templates), top)
    im.DockBuilderDockWindow(tr(.Win_Worlds), right)
    im.DockBuilderFinish(dockspace_id)
}

ui_render_platform_windows :: proc() {
    if .ViewportsEnable in ui.io.ConfigFlags {
        im.UpdatePlatformWindows()
        im.RenderPlatformWindowsDefault()
    }
}

ui_draw :: proc() {
    dx.descriptor_heap_bind(renderer_dx.cmd_gfx, {renderer_dx.ui_heap, renderer_dx.sampler_heap})
    im_dx12.RenderDrawData(im.GetDrawData(), renderer_dx.cmd_gfx.handle)
}

ui_shutdown :: proc() {
    for p in ui.scene_paths do delete(p, app.allocators.perm)
    delete(ui.scene_paths)
    ui_templates_shutdown()
    delete(ui.panels)
    delete(ui.hosts)
    editor_views_shutdown()

    im_dx12.Shutdown()
    im_sdl3.Shutdown()
    im.DestroyContext()
}
