package blimp

import "core:c"
import hm "core:container/handle_map"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import win32 "core:sys/windows"
import lua "vendor:lua/5.1"
import stbi "vendor:stb/image"
import "dx"

// Remote control: a localhost TCP port taking text commands, so tools (bin/blimpctl.exe — and Claude
// through it) can drive the running editor: inspect and edit entities, open worlds, move cameras,
// pick, take screenshots, run Lua.
//
// One request per connection: the client sends a command line, optionally followed by a body (after
// the first '\n'), half-closes its side, then reads the reply until the server closes. The reply's
// first line is `ok` or `error`; the rest is text. Polled once per frame on the main thread before
// the UI, non-blocking, so commands run between frames like any UI action — no threads, no locks.
// A command's effect is rendered by the next frame; blimpctl calls are sequential, so a
// `set` followed by a `screenshot` always sees the change.
//
// Debug builds only, bound to 127.0.0.1. Run `blimpctl help` for the command list.
REMOTE_PORT        :: 47800   // must match tools/blimpctl
REMOTE_MAX_REQUEST :: 1 << 20
REMOTE_TIMEOUT_SEC :: 5.0     // a client that never finishes sending is dropped
REMOTE_CAPTURE_TIMEOUT_SEC :: 15.0

// A failed command's message; nil = success. A Maybe so lookups can `or_return` it straight out of a handler.
@(private="file")
Remote_Error :: Maybe(string)

@(private="file")
Remote_Client :: struct {
    socket: net.TCP_Socket,
    buf:    [dynamic]u8,
    opened: f64,
    wait_captures: u32,   // > 0: request done, reply once RenderDoc has this many captures
    wait_ui_shot:  bool,  // request done (`screenshot ui`), reply once the frame that copied the window has finished
    shot_path:     sbuf256,
}

// Set by a command that answers later (`capture`); read by remote_poll right after it runs.
@(private="file")
remote_wait_captures: u32

// Set by `screenshot ui` to where the PNG goes; remote_poll answers once the next frame has copied the window.
@(private="file")
remote_wait_ui_shot: string

@(private="file")
remote: struct {
    listener: net.TCP_Socket,
    clients:  [dynamic]Remote_Client,   // editor state → general heap
    running:  bool,
}

remote_init :: proc() {
    when !ODIN_DEBUG do return
    sock, err := net.listen_tcp({net.IP4_Loopback, REMOTE_PORT})
    if err != nil {
        log.warnf("Remote control disabled: can't listen on 127.0.0.1:%v (%v)", REMOTE_PORT, err)
        return
    }
    net.set_blocking(sock, false)
    remote_no_inherit(sock)
    remote.listener, remote.running = sock, true
    log.infof("Remote control listening on 127.0.0.1:%v", REMOTE_PORT)
}

// Sockets are inheritable by default, and app_spawn_self inherits handles (for the console): a relaunched
// engine would hold this one's port, and a client would never see its connection close.
@(private="file")
remote_no_inherit :: proc(sock: net.TCP_Socket) {
    win32.SetHandleInformation(win32.HANDLE(uintptr(sock)), win32.HANDLE_FLAG_INHERIT, 0)
}

remote_shutdown :: proc() {
    if !remote.running do return
    for &cl in remote.clients { net.close(cl.socket); delete(cl.buf) }
    delete(remote.clients)
    net.close(remote.listener)
    remote.running = false
}

remote_poll :: proc() {
    if !remote.running do return
    for {
        sock, _, err := net.accept_tcp(remote.listener)
        if err != nil do break   // .Would_Block: nobody waiting
        net.set_blocking(sock, false)
        remote_no_inherit(sock)
        append(&remote.clients, Remote_Client{socket = sock, opened = timer_sec_since_init()})
    }

    now := timer_sec_since_init()
    for i := 0; i < len(remote.clients); i += 1 {
        cl := &remote.clients[i]
        reply: string

        if cl.wait_captures > 0 {
            // A `capture` request: answered once RenderDoc has written the file (a frame later).
            if renderdoc_num_captures() >= cl.wait_captures {
                path, _ := renderdoc_capture_path(cl.wait_captures - 1)
                reply = fmt.tprintf("ok\n%s\n", path)
            } else if now - cl.opened > REMOTE_CAPTURE_TIMEOUT_SEC {
                reply = "error\nRenderDoc didn't produce a capture (see the engine log)\n"
            } else {
                continue
            }
        } else if cl.wait_ui_shot {
            if renderer_dx.ui_shot_frame != 0 {
                reply = remote_ui_shot_reply(sbuf_str(&cl.shot_path))
            } else if now - cl.opened > REMOTE_CAPTURE_TIMEOUT_SEC {
                renderer_dx.ui_shot_requested = false
                reply = "error\nthe window wasn't captured (no frame rendered)\n"
            } else {
                continue
            }
        } else {
            done, failed := false, false
            chunk: [4096]u8
            for {
                n, err := net.recv_tcp(cl.socket, chunk[:])
                if err == .Would_Block do break
                if err != nil { failed = true; break }
                if n == 0 { done = true; break }   // client half-closed: the request is complete
                append(&cl.buf, ..chunk[:n])
                if len(cl.buf) > REMOTE_MAX_REQUEST { failed = true; break }
            }
            if !done && !failed && now - cl.opened < REMOTE_TIMEOUT_SEC do continue

            if done {
                remote_wait_captures = 0
                remote_wait_ui_shot = ""
                reply = remote_execute(string(cl.buf[:]))
                if remote_wait_captures > 0 {   // the command asked to reply later
                    cl.wait_captures, cl.opened = remote_wait_captures, now
                    continue
                }
                if remote_wait_ui_shot != "" {
                    cl.wait_ui_shot, cl.opened = true, now
                    sbuf_set(&cl.shot_path, remote_wait_ui_shot)
                    continue
                }
            }
        }

        if reply != "" {
            net.set_blocking(cl.socket, true)
            net.send_tcp(cl.socket, transmute([]u8)reply)
        }
        net.close(cl.socket)
        delete(cl.buf)
        unordered_remove(&remote.clients, i)
        i -= 1
    }
}

// The reply to a `screenshot ui` whose frame has been submitted: waits for that frame, reads the copy
// and writes the PNG.
@(private="file")
remote_ui_shot_reply :: proc(path: string) -> string {
    dx.fence_wait(renderer_dx.frame_fence_gfx, renderer_dx.ui_shot_frame)
    renderer_dx.ui_shot_frame = 0
    pixels := dx.texture_readback_pixels(renderer_dx.ui_shot, context.temp_allocator)
    abs, err := remote_write_png(path, pixels, renderer_dx.ui_shot.width, renderer_dx.ui_shot.height)
    if msg, failed := err.?; failed do return fmt.tprintf("error\n%s\n", msg)
    return fmt.tprintf("ok\n%s\n", abs)
}

// Writes tightly packed RGBA8 `pixels` to `path` (creating its folder) as an opaque PNG, and returns
// its absolute path.
@(private="file")
remote_write_png :: proc(path: string, pixels: []u8, w, h: u32) -> (abs: string, err: Remote_Error) {
    dir := path[:max(strings.last_index_any(path, "/\\"), 0)]
    if dir != "" do os.make_directory_all(dir)
    for i := 3; i < len(pixels); i += 4 do pixels[i] = 255   // render targets' alpha isn't meaningful
    if stbi.write_png(strings.clone_to_cstring(path, context.temp_allocator), c.int(w), c.int(h), 4, raw_data(pixels), c.int(w * 4)) == 0 {
        return "", fmt.tprintf("couldn't write '%s'", path)
    }
    abs, _ = os.get_absolute_path(path, context.temp_allocator)
    return abs, nil
}

// Runs one request and returns the whole reply text, status line included.
@(private="file")
remote_execute :: proc(request: string) -> string {
    line, _, body := strings.partition(request, "\n")
    args := remote_tokenize(strings.trim_space(line))
    b := strings.builder_make(context.temp_allocator)
    if len(args) == 0 do return "error\nempty request\n"

    if err, failed := remote_command(args[0], args[1:], body, &b).?; failed {
        return fmt.tprintf("error\n%s\n", err)
    }
    return fmt.tprintf("ok\n%s", strings.to_string(b))
}

REMOTE_HELP :: `Worlds and entities  (<world> = index, title, or scene path; <name> = entity name)
  worlds                                  list open worlds
  open <path>                             open a level (.level) or kit (.gltf/.glb)
  close <world>                           close a world and its views
  save <world>                            write a scene world back to its .level
  entities <world>                        one line per entity: name, model, position
  get <world> [name]                      [entity] text of one entity, or of all
  set <world> <name> <field> <value...>   set one field (same syntax as scene files); undoable
  paste <world> -                         add the [entity] blocks in the body (blimpctl: from stdin)
  delete <world> <name>                   delete an entity; undoable
  select <world> <name...|none>           replace the selection; the last name is active
  duplicate <world>                       copy the selection in place and select the copies (Ctrl+D)
  settings <world> [field value...]       show or set the world's [world] settings (undoable)
  play <world> [stop|pause|step]          play the world's level in a copy; stop, toggle pause, or step a frame
  bake <world>                            bake the level's probes (blocks), save its .probes; replies with the stats
  probe <world> <x> <y> <z>               baked indirect irradiance/pi at a point, facing +-X +-Y +-Z (linear)
  rename <world>                          start renaming the active entity in its entity list (F2)
  undo | redo
Views  (<view> = view id, see 'views')
  views                                   list views: id, world, size, camera
  camera <view> [x y z yaw pitch dist]    get or set the camera (pivot, degrees, distance)
  frame <view>                            frame the world's selection (F)
  pick <view> <x> <y> [add|remove|toggle]  click at view pixel x,y (selects; like Shift / Ctrl+Shift / Ctrl)
  marquee <view> <x0> <y0> <x1> <y1> [add|remove|toggle]  marquee-select a view rectangle
  menu <view> <x> <y>                     right-click at view pixel x,y (selects, opens the context menu)
  maximize <view>                         the view fills the main window, or goes back (F11)
  game <view>                             game mode on a playing view (the window is the game, through its camera entity), or back (F8)
  stats [on|off]                          the FPS / GPU-per-pass overlay (F3)
  gameview <view>                         hide / show icons, outlines and the gizmo in the view (G)
  retro <view> [on|off]                   get or set the view's render mode: the retro look, or clean (off);
                                          the effects are the level's settings: settings <world> retro.ps1.on true
  screenshot <view> [path.png]            save the view's last frame (the 3D scene only); replies with the file path
  screenshot ui [path.png]                save the whole main window as shown: views, icons, gizmo, every docked or
                                          floating panel (not panels dragged out into their own OS window)
  timings                                 CPU frame time + GPU time per pass (latest frame)
  sounds                                  loaded sound clips, then each playing voice: clip, world, entity, volume, state
  tool [select|move|...] [global|local] [center|pivots]   get or set the viewport tool, gizmo space and pivot
  resources [show|hide]                   GPU resources by owner (assets, worlds, views, engine), largest first;
                                          shows/hides the GPU Resources window
  shadows <world> [show|hide]             shadow map slices in use: index, light, type, face, texel size;
                                          shows/hides the Shadow Maps window (it shows the active world)
Engine
  restart [--gpu-validation] [--renderdoc]   relaunch with exactly these launch options (none = plain);
                                          refuses while anything is unsaved
RenderDoc  (engine started with --renderdoc, or launched from RenderDoc)
  capture                                 capture the next frame; replies with the .rdc path
  captures                                list this session's captures
  rdui [index]                            open a capture in RenderDoc (default: the latest)
Log
  log [count] [warn|error]                the last log lines (default 20), oldest first; optionally only
                                          warnings and errors, or only errors
Lua
  lua <code...>                           run Lua on the active world; replies with its print()
                                          output, then return values as "=> value"
  lua <world> -                           run the Lua on stdin with World / Entity acting on that world
                                          (a playing level's play world, for collision and sound queries)
`

// The N numbers in `args` (a command's coordinates), or an error naming the one that isn't.
@(private="file")
remote_floats :: proc(args: []string, $N: int) -> (f: [N]f32, err: Remote_Error) {
    for i in 0 ..< N {
        ok: bool
        f[i], ok = strconv.parse_f32(args[i])
        if !ok do return f, fmt.tprintf("not a number: '%s'", args[i])
    }
    return f, nil
}

@(private="file")
remote_command :: proc(cmd: string, args: []string, body: string, out: ^strings.Builder) -> Remote_Error {
    switch cmd {
    case "help":
        strings.write_string(out, REMOTE_HELP)

    case "worlds":
        for w, i in worlds {
            n := 0
            it := hm.iterator_make(&w.entities)
            for _, _ in hm.iterate(&it) do n += 1
            fmt.sbprintf(out, "%d  %s  entities=%d  views=", i, w.title, n)
            sep := ""
            for v in views do if v.world == w { fmt.sbprintf(out, "%s%d", sep, v.id); sep = "," }
            if w.play_world != nil do strings.write_string(out, "  [playing]")
            if w.play_source != nil do fmt.sbprintf(out, "  [play of %s]", w.play_source.title)
            fmt.sbprintf(out, "  %s%s%s\n", w.save_path != "" ? w.save_path : w.play_source != nil ? "(play)" : "(kit)", world_dirty(w) ? "  [unsaved]" : "", active_world() == w ? "  [active]" : "")
        }

    case "open":
        if len(args) < 1 do return "usage: open <path>"
        path := args[0]
        ext := strings.to_lower(path[strings.last_index_byte(path, '.') + 1:], context.temp_allocator)
        w := world_find_open(path)   // already open: focus it, as the Worlds window does, rather than open a second copy
        if w != nil {
            ui_world_focus(w)
        } else if ext == "gltf" || ext == "glb" {
            for &kit in asset_system.kits do if kit.path == path { w = app_open_kit(&kit); break }
            if w == nil do return fmt.tprintf("no loaded kit '%s' (kits are loaded at startup)", path)
        } else {
            if !os.exists(path) do return fmt.tprintf("no file '%s'", path)
            w = app_open_scene(path)
        }
        for v in views do if v.world == w do fmt.sbprintf(out, "opened %s  view=%d\n", w.title, v.id)

    case "close":
        w := remote_world(args) or_return
        world_request_close(w)
        fmt.sbprintf(out, "closing %s\n", w.title)

    case "save":
        w := remote_world(args) or_return
        if w.play_source != nil do return "a play world can't be saved (nothing from play is ever saved)"
        if w.save_path == "" do return "a kit can't be saved"
        if !world_save(w) do return "save failed (see log)"
        fmt.sbprintf(out, "saved %s\n", w.save_path)

    case "entities":
        w := remote_world(args) or_return
        it := hm.iterator_make(&w.entities)
        for e, _ in hm.iterate(&it) {
            fmt.sbprintf(out, "%s  model=%s  position=%v%s\n", sbuf_str(&e.name), e.model, e.position, editor_world(w).active == e.handle ? "  [active]" : e.selected ? "  [selected]" : "")
        }

    case "get":
        w := remote_world(args) or_return
        if len(args) >= 2 {
            e := remote_entity(w, args[1]) or_return
            strings.write_string(out, entity_to_text(e, context.temp_allocator))
        } else {
            it := hm.iterator_make(&w.entities)
            for e, _ in hm.iterate(&it) { strings.write_string(out, entity_to_text(e, context.temp_allocator)); strings.write_byte(out, '\n') }
        }

    case "set":
        if len(args) < 4 do return "usage: set <world> <name> <field> <value...>"
        w := remote_world(args) or_return
        e := remote_entity(w, args[1]) or_return
        before := entity_to_text(e, context.temp_allocator)
        snapshot := e^
        deserialize_field(e, args[2], strings.join(args[3:], " ", context.temp_allocator))
        entity_intern_keys(e)
        world_fix_duplicate_name(w, e.handle)
        after := entity_to_text(e, context.temp_allocator)
        if after == before do return fmt.tprintf("nothing changed (unknown field '%s', or same value)", args[2])
        undo_push_edited(w, e.handle, snapshot)
        strings.write_string(out, after)

    case "paste":
        w := remote_world(args) or_return
        if selection_paste(w, body) == 0 do return "no [entity] blocks in the body (blimpctl: pass '-' and pipe them on stdin)"
        for h in selection_handles(w) do if e, ok := entity_get(w, h); ok do fmt.sbprintf(out, "added %s\n", sbuf_str(&e.name))

    case "delete":
        w := remote_world(args) or_return
        e := remote_entity(w, len(args) > 1 ? args[1] : "") or_return
        h := e.handle
        undo_push(w)
        selection_remove_entity(w, h)
        fmt.sbprintf(out, "deleted\n")

    case "select":
        // Replace the selection with the named entities (or `none`); the last one is active.
        w := remote_world(args) or_return
        if len(args) < 2 do return "usage: select <world> <name...|none>"
        hs := make([dynamic]Entity_Handle, context.temp_allocator)
        if args[1] != "none" do for name in args[1:] {
            e := remote_entity(w, name) or_return
            append(&hs, e.handle)
        }
        selection_clear(w)
        for h in hs do selection_set(w, h, true)

    case "duplicate":
        // Ctrl+D: copy the selection in place and select the copies; undoable.
        w := remote_world(args) or_return
        if selection_count(w) == 0 do return "nothing selected"
        undo_push(w)
        selection_duplicate(w)
        for h in selection_handles(w) do if e, ok := entity_get(w, h); ok do fmt.sbprintf(out, "%s\n", sbuf_str(&e.name))

    case "settings":
        // The world's [world] section; with a field and value, set it (undoable, like the window).
        w := remote_world(args) or_return
        if len(args) >= 3 {
            before := w.settings
            v, ok := struct_field_by_path(w.settings, args[1])
            if !ok do return fmt.tprintf("no world setting '%s'", args[1])
            deserialize_value(v, strings.join(args[2:], " ", context.temp_allocator))
            undo_push_settings_edited(w, before)
        }
        serialize_struct(out, w.settings)

    case "bake":
        w := world_level(remote_world(args) or_return)
        s, ok := bake_probes(w)
        if !ok do return "bake failed (see log)"
        fmt.sbprintf(out, "%v x %v x %v probes  layers=%v  instances=%v  lights=%v  threads=%v  %.2f s  %.2f Mrays/s  backface=%.1f%%  buried=%v\n",
            s.dims.x, s.dims.y, s.dims.z, s.layers, s.instances, s.lights, s.threads, s.seconds, f64(s.rays) / s.seconds / 1e6, 100 * s.backface, s.buried)

    case "probe":
        src := remote_world(args) or_return   // lit by its group scales; a play world reads its level's grid
        w := world_level(src)
        if len(args) < 4 do return "usage: probe <world> <x> <y> <z>"
        p := vec3(remote_floats(args[1:4], 3) or_return)
        if len(w.probes.probes) == 0 do return "not baked"
        dirs  := [6]vec3{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
        names := [6]string{"+X", "-X", "+Y", "-Y", "+Z", "-Z"}
        for d, i in dirs {
            e := probe_grid_sample(&w.probes, p, d, probe_layer_scales(&w.probes, light_group_scales(src)))
            fmt.sbprintf(out, "%s  %.4f %.4f %.4f\n", names[i], e.x, e.y, e.z)
        }

    case "play":
        // Play mode (world_play.odin) on a world's level: play, stop, or toggle pause.
        w := remote_world(args) or_return
        switch len(args) > 1 ? args[1] : "" {
        case "":      app_play(w)
        case "stop":  app_stop(w)
        case "pause": world_pause_toggle(w)
        case "step":  world_step(w)
        case:         return "usage: play <world> [stop|pause|step]"
        }
        p := world_level(w).play_world
        fmt.sbprintf(out, "%s\n", p == nil ? "stopped" : p.paused ? "paused" : "playing")

    case "undo": undo()
    case "redo": redo()

    case "views":
        for v in views {
            c := v.camera
            fmt.sbprintf(out, "%d  world=%s  size=%dx%d  camera=%v %v %v %v%s\n", v.id, v.world.title,
                v.target.width, v.target.height, c.pivot, math.to_degrees(c.yaw), math.to_degrees(c.pitch), c.distance,
                active_view == v ? "  [active]" : "")
        }

    case "camera":
        v := remote_view(args) or_return
        c := &v.camera
        if len(args) >= 7 {
            f := remote_floats(args[1:7], 6) or_return
            c.pivot = {f[0], f[1], f[2]}
            c.yaw, c.pitch, c.distance = math.to_radians(f[3]), math.to_radians(f[4]), max(f[5], CAMERA_MIN_DISTANCE)
        } else if len(args) != 1 {
            return "usage: camera <view> [x y z yaw pitch dist]"
        }
        fmt.sbprintf(out, "%v %v %v %v %v %v\n", c.pivot.x, c.pivot.y, c.pivot.z, math.to_degrees(c.yaw), math.to_degrees(c.pitch), c.distance)

    case "frame":
        v := remote_view(args) or_return
        editor_frame_selection(editor_view(v))

    case "pick":
        // A click at view pixel x,y, exactly as the mouse does it; add / remove / toggle instead of replacing.
        v := remote_view(args) or_return
        if len(args) < 3 do return "usage: pick <view> <x> <y> [add|remove|toggle]"
        xy := remote_floats(args[1:3], 2) or_return
        x, y := xy[0], xy[1]
        ev := editor_view(v)
        hit, ok := view_pick(ev, ev.screen_min + {x, y})
        selection_click(ev, ev.screen_min + {x, y}, remote_selection_op(args[3:]))
        if !ok { strings.write_string(out, "miss\n"); break }
        e := entity_get(v.world, hit.entity) or_break
        if hit.icon do fmt.sbprintf(out, "hit %s  (icon)\n", sbuf_str(&e.name))
        else do fmt.sbprintf(out, "hit %s  point=%v  t=%v\n", sbuf_str(&e.name), hit.point, hit.t)

    case "maximize":
        // F11: the view fills the main window, or goes back.
        v := remote_view(args) or_return
        ui_maximize_toggle(v)
        fmt.sbprintf(out, "%s\n", ui.maximized == v ? "maximized" : "restored")

    case "game":
        // F8: game mode on the view (it must be showing a play world), or back to the editor.
        v := remote_view(args) or_return
        if ui.game == v do ui_game_leave()
        else            do ui_game_enter(v)
        fmt.sbprintf(out, "%s  camera=%v\n", ui.game == v ? "game" : "editor", v.camera_entity)

    case "gameview":
        // G: hide everything editor-only in the view, or show it again.
        v := remote_view(args) or_return
        ui_game_view_toggle(v)
        fmt.sbprintf(out, "%s\n", editor_view(v).game_view ? "on" : "off")

    case "retro":
        // The toolbar's retro toggle; the target rebuilds next frame.
        v := remote_view(args) or_return
        if len(args) > 1 do v.mode = args[1] == "on" ? .Retro : .Clean
        fmt.sbprintf(out, "%s\n", v.mode == .Retro ? "on" : "off")

    case "stats":
        // F3: the stats overlay.
        ui.show_stats = len(args) > 0 ? args[0] == "on" : !ui.show_stats
        fmt.sbprintf(out, "%s\n", ui.show_stats ? "on" : "off")

    case "rename":
        // F2: inline rename of the world's active entity in its entity list.
        w := remote_world(args) or_return
        ui_entity_rename_begin(w)

    case "menu":
        // A right-click at view pixel x,y: selects what's there and opens the context menu next frame.
        v := remote_view(args) or_return
        if len(args) < 3 do return "usage: menu <view> <x> <y>"
        xy := remote_floats(args[1:3], 2) or_return
        editor_view(v).remote_context = vec2(xy)

    case "marquee":
        // A marquee drag between two view pixels, exactly as the mouse does it; add / remove / toggle as for pick.
        v := remote_view(args) or_return
        if len(args) < 5 do return "usage: marquee <view> <x0> <y0> <x1> <y1> [add|remove|toggle]"
        c := remote_floats(args[1:5], 4) or_return
        ev := editor_view(v)
        a, b := ev.screen_min + {c[0], c[1]}, ev.screen_min + {c[2], c[3]}
        selection_marquee(ev, linalg.min(a, b), linalg.max(a, b), remote_selection_op(args[5:]))
        for h in selection_handles(v.world) do if e, eok := entity_get(v.world, h); eok do fmt.sbprintf(out, "%s\n", sbuf_str(&e.name))

    case "screenshot":
        if len(args) >= 1 && args[0] == "ui" {
            // The swapchain image is copied inside the next frame (render_dx.odin); remote_poll replies then.
            if renderer_dx.ui_shot_requested || renderer_dx.ui_shot_frame != 0 do return "a window screenshot is already in progress"
            renderer_dx.ui_shot_requested = true
            remote_wait_ui_shot = len(args) >= 2 ? args[1] : "out/screenshots/ui.png"
            break
        }
        v := remote_view(args) or_return
        path := len(args) >= 2 ? args[1] : fmt.tprintf("out/screenshots/view%d.png", v.id)
        renderer_dx_wait_idle()
        pixels, w, h, ok := dx.texture_readback_rgba8(renderer_dx.render_context, renderer_dx.cmd_queue_gfx, &v.target.tex, context.temp_allocator)
        if !ok do return "view hasn't rendered yet"
        abs := remote_write_png(path, pixels, w, h) or_return
        fmt.sbprintf(out, "%s\n", abs)

    case "tool":
        // The viewport tool (toolbar / Q W E R), for driving the editor without the mouse.
        for a in args {
            switch a {
            case "select": ui.tool = .Select
            case "move":   ui.tool = .Move
            case "rotate": ui.tool = .Rotate
            case "scale":  ui.tool = .Scale
            case "global": ui.space = .Global
            case "local":  ui.space = .Local
            case "center": ui.pivot = .Selection_Center
            case "pivots": ui.pivot = .Individual_Pivots
            case:          return "usage: tool [select|move|rotate|scale] [global|local] [center|pivots]"
            }
        }
        fmt.sbprintf(out, "%v %v %v\n", ui.tool, ui.space, ui.pivot)

    case "resources":
        // The GPU Resources window's data as text (ui_resources.odin).
        if len(args) > 0 do ui.show_resources = args[0] == "show"
        for it in resource_items() {
            fmt.sbprintf(out, "%-10v %10s  %s / %s  (%s)\n", it.kind, bytes_text(it.bytes), it.owner, it.name, it.detail)
        }

    case "shadows":
        // The Shadow Maps window's data as text (ui_shadows.odin).
        w := remote_world(args) or_return
        if len(args) > 1 do ui.show_shadow_maps = args[1] == "show"
        r := &w.render
        fmt.sbprintf(out, "%d / %d slices, %d shadowed lights without one, %dx%d each\n", len(r.shadow_slices), MAX_SHADOW_SLICES, r.shadow_missed, SHADOW_MAP_SIZE, SHADOW_MAP_SIZE)
        for &s, i in r.shadow_slices {
            fmt.sbprintf(out, "%2d  %-24s %-11v face %d  texel %.4f%s\n", i, sbuf_str(&s.light), s.light_type, s.face, s.texel, s.far > 0 ? " at 1 m" : "")
        }

    case "timings":
        // GPU: per-pass timestamps from the latest completed frame (render_gpu_timer.odin), nested by indent.
        fmt.sbprintf(out, "%-32s %.3f ms\n", "cpu frame", timer_delta_sec() * 1000)
        for &t in gpu_timings {
            label := fmt.tprintf("%*s%s", t.depth * 2, "", sbuf_str(&t.name))
            fmt.sbprintf(out, "gpu %-28s %.3f ms\n", label, t.ms)
        }

    case "sounds":
        if !sound_system.ok do return "no audio device"
        fmt.sbprintf(out, "%v clips:", len(sound_system.clips))
        for c in sound_system.clips do fmt.sbprintf(out, " %s", c.key)
        strings.write_byte(out, '\n')
        for &v, i in sound_system.voices {
            if v.clip < 0 do continue
            name := "-"
            if e, ok := entity_get(v.world, v.entity); ok && v.entity != {} do name = sbuf_str(&e.name)
            fmt.sbprintf(out, "voice %v  %s  world=%s  entity=%s  volume=%.2f  %s%s%s\n", i, sound_system.clips[v.clip].key, v.world.title, name, v.volume,
                v.positional ? "positional " : "", v.looping ? "loop " : "", v.paused ? "paused" : "playing")
        }

    case "restart":
        for a in args do switch a {
        case "--gpu-validation", "--renderdoc":   // every launch option the engine reads
        case: return fmt.tprintf("unknown launch option '%s' (known: --gpu-validation --renderdoc)", a)
        }
        for w in worlds do if world_dirty(w) do return fmt.tprintf("'%s' has unsaved changes: save it first", w.title)
        log.infof("Remote: restarting with %v", args)
        app_spawn_self(args)
        app.quit_requested = true   // the main loop exits after this frame's UI; the reply goes out first

    case "capture":
        if !renderdoc_active() do return "RenderDoc isn't active: start the engine with --renderdoc (or launch it from RenderDoc)"
        renderdoc_request_capture()
        remote_wait_captures = renderdoc_num_captures() + 1   // remote_poll replies with its path once written

    case "captures":
        if !renderdoc_active() do return "RenderDoc isn't active"
        for i in 0 ..< renderdoc_num_captures() {
            if path, ok := renderdoc_capture_path(i); ok do fmt.sbprintf(out, "%d  %s\n", i, path)
        }

    case "rdui":
        n := renderdoc_num_captures()
        if n == 0 do return "no captures yet (run 'capture' first)"
        idx := n - 1
        if len(args) > 0 {
            i, ok := strconv.parse_int(args[0])
            if !ok || i < 0 || i >= int(n) do return fmt.tprintf("no capture %s (see 'captures')", args[0])
            idx = u32(i)
        }
        path, _ := renderdoc_capture_path(idx)
        if _, err := os.process_start({command = {RENDERDOC_UI, path}}); err != nil do return fmt.tprintf("couldn't start %s: %v", RENDERDOC_UI, err)
        fmt.sbprintf(out, "opened %s\n", path)

    case "log":
        n, min_level := 20, log.Level.Info
        for a in args {
            switch a {
            case "warn", "warning": min_level = .Warning
            case "error":           min_level = .Error
            case:
                v, ok := strconv.parse_int(a)
                if !ok || v <= 0 do return "usage: log [count] [warn|error]"
                n = v
            }
        }
        for &e in log_history_recent(n, min_level) do fmt.sbprintfln(out, "%.2fs  %v  %s", e.time, e.level, sbuf_str(&e.text))

    case "lua":
        // print() output is captured into the reply while the code runs (and still echoed to the
        // console); return values follow, each as "=> value". The original print is restored after.
        // With a body (blimpctl lua <world> -), the one argument names the world the World / Entity calls act on.
        code := len(args) > 0 ? strings.join(args, " ", context.temp_allocator) : body
        target := active_world()
        if body != "" && len(args) == 1 {
            target = remote_world(args) or_return
            code = body
        }
        // Lua that changes a level is an edit like any other: undoable, and it dirties the level. A query
        // changes nothing, so its snapshot is dropped again.
        recorded := target != nil && undo_push(target)
        defer if recorded do undo_drop_if_unchanged(target)
        prev := lua_world_target(target)
        defer lua_world_target(prev)
        L := lua_system.L
        top := lua.gettop(L)
        defer lua.settop(L, top)
        lua.getglobal(L, "print")   // stack[top+1]: the original, restored below
        lua.pushcfunction(L, remote_lua_print)
        lua.setglobal(L, "print")
        remote_print_out = out
        defer {
            remote_print_out = nil
            lua.pushvalue(L, top + 1)
            lua.setglobal(L, "print")
        }
        if lua.L_loadstring(L, strings.clone_to_cstring(code, context.temp_allocator)) != .OK || lua.pcall(L, 0, lua.MULTRET, 0) != 0 {
            return fmt.tprintf("%slua: %s", strings.to_string(out^), lua.tostring(L, -1))
        }
        for i in top + 2 ..= lua.gettop(L) {
            fmt.sbprintf(out, "=> %s\n", remote_lua_tostring(L, c.int(i)))
            lua.pop(L, 1)   // remote_lua_tostring leaves its string on the stack
        }

    case:
        return fmt.tprintf("unknown command '%s' (try 'help')", cmd)
    }
    return nil
}

/* --------------------------------- Lookups -------------------------------- */
// Each returns an error message on failure, so handlers can `or_return` it as their own result.

@(private="file")
remote_world :: proc(args: []string) -> (^World, Remote_Error) {
    if len(args) == 0 do return nil, "missing <world> (index, title, or scene path)"
    ref := args[0]
    if i, ok := strconv.parse_int(ref); ok && i >= 0 && i < len(worlds) do return worlds[i], nil
    for w in worlds do if w.title == ref || w.save_path == ref do return w, nil
    return nil, fmt.tprintf("no open world '%s' (see 'worlds')", ref)
}

@(private="file")
remote_entity :: proc(w: ^World, name: string) -> (^Entity, Remote_Error) {
    if name == "" do return nil, "missing entity name"
    h, ok := world_find(w, name)
    if !ok do return nil, fmt.tprintf("no entity '%s' in %s", name, w.title)
    return entity_get(w, h), nil
}

@(private="file")
remote_view :: proc(args: []string) -> (^Render_View, Remote_Error) {
    if len(args) == 0 do return nil, "missing <view> id (see 'views')"
    id, ok := strconv.parse_int(args[0])
    if ok do for v in views do if int(v.id) == id do return v, nil
    return nil, fmt.tprintf("no view '%s' (see 'views')", args[0])
}

// Splits on whitespace; "double quotes" group words (entity names may contain spaces).
@(private="file")
remote_tokenize :: proc(s: string) -> []string {
    out := make([dynamic]string, context.temp_allocator)
    i := 0
    for i < len(s) {
        for i < len(s) && strings.is_space(rune(s[i])) do i += 1
        if i >= len(s) do break
        if s[i] == '"' {
            end := strings.index_byte(s[i + 1:], '"')
            if end < 0 { append(&out, s[i + 1:]); break }
            append(&out, s[i + 1:][:end])
            i += end + 2
        } else {
            start := i
            for i < len(s) && !strings.is_space(rune(s[i])) do i += 1
            append(&out, s[start:i])
        }
    }
    return out[:]
}

/* ---------------------------------- Lua ----------------------------------- */

// Where the `lua` command's print() goes while it runs; nil otherwise.
@(private="file")
remote_print_out: ^strings.Builder

// Stand-in for print() during a `lua` command: same formatting (tab-separated, tostring'd).
@(private="file")
remote_lua_print :: proc "c" (L: ^lua.State) -> c.int {
    context = app.g_context
    n := lua.gettop(L)
    line := strings.builder_make(context.temp_allocator)
    for i in 1 ..= n {
        if i > 1 do strings.write_byte(&line, '\t')
        strings.write_string(&line, string(remote_lua_tostring(L, i)))
        lua.pop(L, 1)
    }
    fmt.println(strings.to_string(line))   // keep the console echo print() always had
    if remote_print_out != nil do fmt.sbprintln(remote_print_out, strings.to_string(line))
    return 0
}

// Lua 5.1 has no luaL_tolstring: format through the global tostring() so tables/nil/bools work.
// Leaves the resulting string on the stack (the caller pops it).
@(private="file")
remote_lua_tostring :: proc(L: ^lua.State, idx: c.int) -> cstring {
    lua.getglobal(L, "tostring")
    lua.pushvalue(L, idx)
    lua.call(L, 1, 1)
    return lua.tostring(L, -1)
}

// The optional selection-op word after a pick / marquee ("ctrl" kept as toggle).
@(private="file")
remote_selection_op :: proc(rest: []string) -> Selection_Op {
    if len(rest) == 0 do return .Replace
    switch rest[0] {
    case "add":            return .Add
    case "remove":         return .Remove
    case "toggle", "ctrl": return .Toggle
    }
    return .Replace
}
