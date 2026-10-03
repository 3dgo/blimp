package blimp

import "core:log"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sys/windows"
import "common"

// Hot reload: a directory watcher on assets/ and assets_engine/ (ReadDirectoryChangesW, polled once a
// frame, no thread). What changed decides what reloads:
//   .gltf .glb .bin .png  every asset (asset_system_reload): kits share textures, so one rebuild is simplest
//   .slang                every pipeline (render_shaders_reload), all or nothing
//   .wav .ogg .mp3 .flac  every sound clip (sound_reload); playing voices stop
//   .luacn                transpiled to its .lua, which then reloads like any .lua
//   .lua                  world scripts loaded from it rerun from the top, start included;
//                         assets/scripts/main.lua reruns and its engine hooks are re-resolved
// Editors and exporters write a file in several steps (3ds Max writes .bin then .gltf), so a change
// waits HOT_RELOAD_SETTLE_SEC after the last event before anything reloads.
HOT_RELOAD_SETTLE_SEC :: 0.3
HOT_RELOAD_ROOTS :: [?]string{"assets", "assets_engine"}

Hot_Reload :: struct {
    watchers: [len(HOT_RELOAD_ROOTS)]File_Watcher,
    assets, shaders, sounds: bool,   // pending reloads
    scripts: [dynamic]string,        // pending .lua paths (project-relative), cloned with app.allocators.perm
    luacn:   [dynamic]string,        // pending .luacn paths
    last_event: f64,                 // timer_sec_since_init of the last event
}
hot_reload: Hot_Reload

hot_reload_init :: proc() {
    for root, i in HOT_RELOAD_ROOTS do file_watcher_open(&hot_reload.watchers[i], root)
    hot_reload.scripts = make([dynamic]string, app.allocators.perm)
    hot_reload.luacn   = make([dynamic]string, app.allocators.perm)
}

hot_reload_shutdown :: proc() {
    for &w in hot_reload.watchers do file_watcher_destroy(&w)
    for s in hot_reload.scripts do delete(s, app.allocators.perm)
    for s in hot_reload.luacn do delete(s, app.allocators.perm)
    delete(hot_reload.scripts)
    delete(hot_reload.luacn)
}

// Once a frame, at the top of the frame (it may wait for the GPU and rebuild assets).
hot_reload_update :: proc() {
    h := &hot_reload
    roots := HOT_RELOAD_ROOTS
    for &w, i in h.watchers {
        changed, overflowed := file_watcher_poll(&w, context.temp_allocator)
        if overflowed {
            log.warnf("Hot reload: too many changes under %v at once; reloading assets and shaders", roots[i])
            h.assets, h.shaders = true, true
            h.last_event = timer_sec_since_init()
        }
        for rel in changed {
            path := strings.concatenate({roots[i], "/", rel}, context.temp_allocator)
            switch strings.to_lower(filepath.ext(path), context.temp_allocator) {
            case ".gltf", ".glb", ".bin", ".png": h.assets = true
            case ".slang":                        h.shaders = true
            case ".wav", ".ogg", ".mp3", ".flac": h.sounds = true
            case ".lua":   if !slice.contains(h.scripts[:], path) do append(&h.scripts, strings.clone(path, app.allocators.perm))
            case ".luacn": if !slice.contains(h.luacn[:], path)   do append(&h.luacn, strings.clone(path, app.allocators.perm))
            case: continue
            }
            h.last_event = timer_sec_since_init()
        }
    }

    pending := h.assets || h.shaders || h.sounds || len(h.scripts) > 0 || len(h.luacn) > 0
    if !pending || timer_sec_since_init() - h.last_event < HOT_RELOAD_SETTLE_SEC do return

    if h.assets {
        h.assets = false
        log.info("Hot reload: assets")
        app_reload_assets()
        log.infof("Hot reload: assets done (%v kits, %v meshes)", len(asset_system.kits), len(asset_system.meshes))
    }
    if h.shaders {
        h.shaders = false
        log.info("Hot reload: shaders")
        render_shaders_reload()
    }
    if h.sounds {
        h.sounds = false
        log.info("Hot reload: sounds")
        sound_reload()
    }
    // Transpiling writes the .lua, which the watcher reports next frame and reloads then.
    for p in h.luacn {
        common.luacn_convert(p)
        delete(p, app.allocators.perm)
    }
    clear(&h.luacn)
    for p in h.scripts {
        lua_reload_script(p)
        delete(p, app.allocators.perm)
    }
    clear(&h.scripts)
}

// ============================ Directory watcher ============================

ERROR_IO_INCOMPLETE :: 996

// One directory tree, watched with an overlapped ReadDirectoryChangesW that is re-armed after each poll.
// The kernel writes into `overlapped` and `buffer` while armed, so a watcher must not move once opened.
File_Watcher :: struct {
    handle:     windows.HANDLE,
    overlapped: windows.OVERLAPPED,
    buffer:     [64 * 1024]byte `fmt:"-"`,   // one batch of FILE_NOTIFY_INFORMATION records
}

file_watcher_open :: proc(w: ^File_Watcher, dir: string) {
    w.handle = windows.CreateFileW(
        windows.utf8_to_wstring(dir, context.temp_allocator),
        windows.FILE_LIST_DIRECTORY,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
        nil,
        windows.OPEN_EXISTING,
        windows.FILE_FLAG_BACKUP_SEMANTICS | windows.FILE_FLAG_OVERLAPPED,
        nil,
    )
    if w.handle == windows.INVALID_HANDLE_VALUE {
        log.errorf("Hot reload: can't watch %v (error %v)", dir, windows.GetLastError())
        w.handle = nil
        return
    }
    w.overlapped.hEvent = windows.CreateEventW(nil, true, false, nil)
    file_watcher_arm(w)
}

file_watcher_destroy :: proc(w: ^File_Watcher) {
    if w.handle == nil do return
    if windows.CancelIoEx(w.handle, &w.overlapped) {
        bytes: windows.DWORD
        windows.GetOverlappedResult(w.handle, &w.overlapped, &bytes, true)
    }
    windows.CloseHandle(w.handle)
    windows.CloseHandle(w.overlapped.hEvent)
    w.handle = nil
}

// The files (relative to the watched directory, forward slashes) changed since the last poll: modified,
// added, or renamed to. Deletions are left out; nothing reloads for a file that's gone. `overflowed`
// means the batch didn't fit and its contents are lost, so assume anything changed.
file_watcher_poll :: proc(w: ^File_Watcher, allocator := context.allocator) -> (changed: []string, overflowed: bool) {
    if w.handle == nil do return
    bytes: windows.DWORD
    if !windows.GetOverlappedResult(w.handle, &w.overlapped, &bytes, false) {
        err := windows.GetLastError()
        if err == ERROR_IO_INCOMPLETE do return   // nothing yet
        log.errorf("Hot reload: watcher error %v", err)
        file_watcher_arm(w)
        return
    }
    if bytes == 0 {
        file_watcher_arm(w)
        return nil, true
    }

    list := make([dynamic]string, allocator)
    offset: u32
    for {
        info := (^windows.FILE_NOTIFY_INFORMATION)(&w.buffer[offset])
        name16 := slice.from_ptr((^u16)(&info.FileName[0]), int(info.FileNameLength / 2))
        if name, err := windows.utf16_to_utf8(name16, allocator); err == nil {
            switch info.Action {
            case windows.FILE_ACTION_ADDED, windows.FILE_ACTION_MODIFIED, windows.FILE_ACTION_RENAMED_NEW_NAME:
                name, _ = strings.replace_all(name, "\\", "/", allocator)
                append(&list, name)
            }
        }
        if info.NextEntryOffset == 0 do break
        offset += info.NextEntryOffset
    }
    file_watcher_arm(w)
    return list[:], false
}

@(private="file")
file_watcher_arm :: proc(w: ^File_Watcher) {
    if !windows.ReadDirectoryChangesW(w.handle, &w.buffer[0], u32(len(w.buffer)), true,
        windows.FILE_NOTIFY_CHANGE_LAST_WRITE | windows.FILE_NOTIFY_CHANGE_FILE_NAME, nil, &w.overlapped, nil) {
        log.errorf("Hot reload: ReadDirectoryChangesW failed (error %v)", windows.GetLastError())
    }
}
