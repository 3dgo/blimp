package blimp

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/windows"
import sdl "vendor:sdl3"

main :: proc() {
    app_init()
    app_run()
    app_shutdown()
}

WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720

FRAME_ALLOCATOR_SIZE :: mem.Megabyte * 100
TEMP_ALLOCATOR_SIZE :: mem.Megabyte * 128

FRAMES_IN_FLIGHT :: 2

App :: struct {
    g_context: runtime.Context,
    old_context: runtime.Context,
    loggers: App_Loggers,
    allocators: App_Allocators,
    
    window: ^sdl.Window,
    window_id: sdl.WindowID,
    window_hwnd: windows.HWND,
    window_width: u32,
    window_height: u32,
    resized: bool,
    dispaly_scale: f32,

    should_restart: bool,   // set by the schema editor Apply to exit the loop after a rebuild
    quit_requested: bool,   // the unsaved-changes prompt said go ahead and quit (ui_unsaved.odin)
}
app: App

App_Loggers :: struct {
    console: runtime.Logger,
}

App_Allocators :: struct {
    perm:  runtime.Allocator,
    frame: runtime.Allocator,
    temp: runtime.Allocator,

    heap_tracker: mem.Tracking_Allocator,

    frame_arena: vmem.Arena,

    temp_arena: vmem.Arena,
    temp_guard: Panic_On_Fail,
}

app_init :: proc() {
    windows.SetConsoleOutputCP(.UTF8)
    
    timer_init()

    app.old_context = context

    init_loggers()
    init_app_allocators()
    setup_context()
    context = app.g_context

    app_enter_project_dir()

    sdl.SetLogPriorities(.VERBOSE)
    sdl.SetLogOutputFunction(log_sdl, nil)

    ok := sdl.Init({.VIDEO, .GAMEPAD})
    if !ok do log.panicf("Can't initialize SDL. %s", sdl.GetError())

    app.dispaly_scale = sdl.GetDisplayContentScale(sdl.GetPrimaryDisplay())

    app.window_width = WINDOW_WIDTH
    app.window_height = WINDOW_HEIGHT
    app.window = sdl.CreateWindow("Blimp", i32(app.window_width), i32(app.window_height), {.HIDDEN, .RESIZABLE, .HIGH_PIXEL_DENSITY})
    app.window_id = sdl.GetWindowID(app.window)
    if app.window == nil do log.panicf("Can't create window. %s", sdl.GetError())

    props := sdl.GetWindowProperties(app.window)
    app.window_hwnd = (windows.HWND)(sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil))
    if app.window_hwnd == nil do log.panic("Failed to get window handle")

    sdl.SetWindowPosition(app.window, sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED)
    
    sdl.ShowWindow(app.window)

    free_all(context.temp_allocator)
    free_all(app.allocators.frame)
    
    os.remove(EXE_OLD_PATH)   // best effort: clear the exe left behind by a previous Apply & Restart

    asset_system_init()

    lua_init()
    sound_init()

    renderdoc_init()   // before the D3D12 device exists, so RenderDoc can hook it
    renderer_dx_init()
    game_settings_load()
    ui_init()
    remote_init()   // debug builds: blimpctl / tool access on 127.0.0.1
    when ODIN_DEBUG do hot_reload_init()   // assets, shaders and scripts reload when their files change
    ui_game_start()   // Game Settings' start level; a release build plays it
}

app_run :: proc() {
    context = app.g_context
    timer_start()
    lua_start()

    main_loop: for {
        timer_frame_begin()
        free_all(context.temp_allocator)
        free_all(app.allocators.frame)
        when ODIN_DEBUG do hot_reload_update()   // first: an asset reload waits for the GPU and rebuilds the asset arena

        app.resized = false
        event: sdl.Event
        for sdl.PollEvent(&event) {
            #partial switch event.type {
                case .WINDOW_RESIZED: {
                    if event.window.windowID == app.window_id {
                        app.window_width = u32(event.window.data1)
                        app.window_height = u32(event.window.data2)
                        app.resized = true
                        renderer_dx_resize_window({app.window_width, app.window_height})
                    }
                }
                // Quit asks first if any world has unsaved changes. Only the main window's close quits;
                // other windows (ImGui platform windows dragged out) are the UI backend's to handle.
                case .WINDOW_CLOSE_REQUESTED: {
                    if event.window.windowID == app.window_id && ui_request_quit() do break main_loop
                }
                case .QUIT: {
                    if ui_request_quit() do break main_loop
                }
                // F9 relaunches the engine (F12 is left to RenderDoc's capture key). Like quitting, it asks
                // first if anything is unsaved; the
                // prompt then relaunches it if the user goes ahead (ui_unsaved.odin).
                case .KEY_DOWN: {
                    if event.key.key == sdl.K_F9 && !event.key.repeat && ui_request_restart() {
                        log.info("F9: restarting (nothing unsaved)")
                        app_spawn_self(os.args[1:])
                        break main_loop
                    }
                }
            }
            ui_process_event(&event)
        }

        app_process_closes()   // closes requested last frame, before anything this frame can reference them
        input_update(ui.game != nil)   // before anything the game runs reads it; live only in game mode
        lua_update(timer_delta_sec())
        world_play_tick(timer_delta_sec())     // which play worlds advance this frame (pause / F10 step), and their clocks
        lua_worlds_update(timer_delta_sec())   // each open world's script (lua_world_script.odin)
        physics_update()                       // after the game systems moved things: kinematic bodies follow
        sound_update(app_listener())           // after the game systems moved things: voices follow, pause, finish

        remote_poll()   // tool commands run between frames, before the UI sees this frame
        ui_update()
        if app.should_restart do break main_loop   // schema editor Apply already built + spawned the new exe
        if app.quit_requested do break main_loop   // confirmed in the unsaved-changes prompt

        for v in views do ui_view_debug_lines(v)   // each view's editor lines, before the renderer uploads them
        renderdoc_frame_begin()
        renderer_dx_draw_frame()
        ui_draw()
        renderer_dx_submit()
        ui_render_platform_windows()
        renderer_dx_present()
        renderdoc_frame_end()

    }
}

// Who the player hears through: the view showing a playing world (the game view first), else the active
// view — through its camera entity when it renders through one, else its free camera.
app_listener :: proc() -> Maybe(Sound_Listener) {
    lv: ^Render_View
    for v in views do if v.world.play_source != nil && (lv == nil || v == ui.game) do lv = v
    if lv == nil do lv = active_view
    if lv == nil do return nil
    if e, ok := render_view_camera_entity(lv); ok do return Sound_Listener{e.position, entity_forward(e)}
    return Sound_Listener{camera_eye(lv.camera), camera_forward(lv.camera)}
}

EXE_PATH     :: "bin/blimp.exe"
EXE_OLD_PATH :: "bin/blimp_old.exe"

// Every path is relative to the working directory, which is only right when launched from the project
// root (VS Code, a terminal). Walk up from the exe's folder to the first one holding assets/ and make it
// the working directory: bin/blimp.exe finds the project root, out/game/game.exe its own folder.
app_enter_project_dir :: proc() {
    dir, err := os.get_executable_directory(context.temp_allocator)
    if err != nil do return
    for {
        assets, _ := filepath.join({dir, "assets"}, context.temp_allocator)
        if os.is_dir(assets) {
            os.set_working_directory(dir)
            return
        }
        parent := filepath.dir(dir)
        if parent == dir do break
        dir = parent
    }
    log.warn("No assets/ folder above the exe; keeping the working directory")
}

// Relaunches the engine with `flags` (launch options such as --renderdoc; pass os.args[1:] to keep this
// run's), passing the std handles through so the new process keeps the console. Without this the child
// (and any build.exe it later spawns) gets dead std handles — output vanishes and the next Apply's build
// fails on its children's invalid handles.
app_spawn_self :: proc(flags: []string) {
    command := make([dynamic]string, context.temp_allocator)
    append(&command, "./" + EXE_PATH)
    append(&command, ..flags)
    _, _ = os.process_start(os.Process_Desc{
        command = command[:],
        stdin   = os.stdin,
        stdout  = os.stdout,
        stderr  = os.stderr,
    })
}

// Opens a File Explorer window on the folder holding `path` (project-relative or absolute), with the
// file selected: find a level or kit to edit and resave it outside the engine.
app_show_in_explorer :: proc(path: string) {
    abs, _ := filepath.abs(path, context.temp_allocator)
    if !os.exists(abs) {
        log.warnf("Show in Explorer: no file at %s", abs)
        return
    }
    abs, _ = strings.replace_all(abs, "/", "\\", context.temp_allocator)
    params := windows.utf8_to_wstring(fmt.tprintf("/select,\"%s\"", abs), context.temp_allocator)
    windows.ShellExecuteW(nil, windows.L("open"), windows.L("explorer.exe"), params, nil, windows.SW_SHOWNORMAL)
}

// Rebuilds the engine (`odin run build.odin`: codegen from entity_schema.ini + recompile) and, on
// success, launches the freshly built exe and asks the main loop to exit into normal shutdown.
// Returns false (without restarting) if the build fails, so the caller can surface the error.
app_rebuild_and_restart :: proc() -> bool {
    // Windows locks the running .exe, so the linker can't overwrite it in place. Rename the
    // running exe aside (allowed while running) so the build can write a fresh bin/blimp.exe.
    os.remove(EXE_OLD_PATH)   // best effort: clear a leftover from a previous restart
    if err := os.rename(EXE_PATH, EXE_OLD_PATH); err != nil {
        log.errorf("Apply: could not move running exe out of the way: %v", err)
        return false
    }

    // Build via `odin run` of build.odin (the single source of build steps). Emit the compiled
    // build script to the system temp dir so we never create/lock a build.exe inside the
    // project tree — a file watcher/AV can hold a freshly-linked exe there, causing LNK1104.
    tmp := os.get_env("TEMP", context.temp_allocator)
    if tmp == "" do tmp = os.get_env("TMP", context.temp_allocator)
    if tmp == "" do tmp = "bin"
    build_out := fmt.tprintf("-out:%v/blimp_build.exe", tmp)
    build := os.Process_Desc{command = {"odin", "run", "build.odin", "-file", build_out}, stdin = os.stdin, stdout = os.stdout, stderr = os.stderr}
    process, start_err := os.process_start(build)
    if start_err != nil {
        log.errorf("Apply: could not start build: %v", start_err)
        os.rename(EXE_OLD_PATH, EXE_PATH)   // restore so the exe still exists
        return false
    }
    state, wait_err := os.process_wait(process)
    if wait_err != nil || state.exit_code != 0 {
        log.errorf("Apply: build failed (exit %v, err %v)", state.exit_code, wait_err)
        os.rename(EXE_OLD_PATH, EXE_PATH)   // restore so the exe still exists
        return false
    }

    app_spawn_self(os.args[1:])
    app.should_restart = true
    return true
}

app_shutdown :: proc() {
    context = app.g_context

    renderer_dx_wait_idle()   // GPU must be idle before tearing down any resources it may still reference
    remote_shutdown()
    when ODIN_DEBUG do hot_reload_shutdown()
    app_close_all()           // opened worlds/views go before the heaps they live in
    world_registry_shutdown()
    sound_shutdown()
    input_shutdown()
    undo_shutdown()

    lua_finish()
    ui_shutdown()
    renderer_dx_shutdown()
    lua_shutdown()
    asset_system_shutdown()

    sdl.DestroyWindow(app.window)
    sdl.Quit()

    destroy_app_allocators()
    context = app.old_context
    destroy_loggers()
}

init_loggers :: proc() {
    app.loggers.console = log.create_console_logger(allocator = context.allocator)
}

destroy_loggers :: proc() {
    log.destroy_console_logger(app.loggers.console, allocator = context.allocator)
}

init_app_allocators :: proc() {
    heap := runtime.heap_allocator()
    mem.tracking_allocator_init(&app.allocators.heap_tracker, heap)

    app.allocators.perm = mem.tracking_allocator(&app.allocators.heap_tracker)

    if err := vmem.arena_init_static(&app.allocators.frame_arena, FRAME_ALLOCATOR_SIZE); err != nil {
        log.panicf("Failed to init frame arena: %v", err)
    }
    app.allocators.frame = frame_allocator(&app.allocators)

    if err := vmem.arena_init_static(&app.allocators.temp_arena, TEMP_ALLOCATOR_SIZE); err != nil {
        log.panicf("Failed to init temp arena: %v", err)
    }
    app.allocators.temp_guard.backing = vmem.arena_allocator(&app.allocators.temp_arena)
    app.allocators.temp = panic_on_fail_allocator(&app.allocators.temp_guard)

    context.allocator = app.allocators.perm
    context.temp_allocator = app.allocators.temp
}

destroy_app_allocators :: proc() {
    // Audit + tracker teardown first, while the temp arena is still alive:
    // audit_memory logs through context.temp_allocator, which is the temp arena.
    context.allocator = runtime.heap_allocator()
    audit_memory()
    mem.tracking_allocator_destroy(&app.allocators.heap_tracker)

    vmem.arena_destroy(&app.allocators.frame_arena)
    vmem.arena_destroy(&app.allocators.temp_arena)
}

audit_memory :: proc() {
    heap_tracker := &app.allocators.heap_tracker
    if len(heap_tracker.allocation_map) > 0 {
        log.warnf("=== %v allocations not freed: ===\n", len(heap_tracker.allocation_map))
        for _, entry in heap_tracker.allocation_map {
            log.warnf("- %v bytes @ %v\n", entry.size, entry.location)
        }
    }
    if len(heap_tracker.bad_free_array) > 0 {
        log.warnf("=== %v incorrect frees: ===\n", len(heap_tracker.bad_free_array))
        for entry in heap_tracker.bad_free_array {
            log.warnf("- %p @ %v\n", entry.memory, entry.location)
        }
    }
}

setup_context :: proc() {
    app.g_context = context
    app.g_context.logger    = app.loggers.console
    app.g_context.allocator = app.allocators.perm
    app.g_context.temp_allocator = app.allocators.temp
}

log_sdl :: proc "c" (userdata: rawptr, category: sdl.LogCategory, priority: sdl.LogPriority, message: cstring) {
    sdl_log_context := app.g_context
    sdl_log_context.logger.options -= {.Short_File_Path, .Line, .Procedure}
    context = sdl_log_context

    level: log.Level
    switch priority {
        case .INVALID, .TRACE, .VERBOSE, .DEBUG: level = .Debug
        case .INFO: level = .Info
        case .WARN: level = .Warning
        case .ERROR: level = .Error
        case .CRITICAL: level = .Fatal
    }
    log.logf(level, "SDL {}: {}", category, message)
}