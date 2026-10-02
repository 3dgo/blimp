package blimp

import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import win32 "core:sys/windows"

// RenderDoc in-application API (renderdoc_app.h), driven from blimpctl: `capture` grabs the next
// frame to an .rdc, `captures` lists them, `rdui` opens one in RenderDoc.
//
// RenderDoc must hook D3D12 before the device exists, so renderdoc_init runs before
// renderer_dx_init. It's active when the engine was launched by RenderDoc (renderdoc.dll already
// injected) or started with `--renderdoc`, which loads the installed DLL. Otherwise it's never
// loaded: hooking costs frame time and changes how the debug layer behaves.
RENDERDOC_DLL     :: `C:\Program Files\RenderDoc\renderdoc.dll`
RENDERDOC_UI      :: `C:\Program Files\RenderDoc\qrenderdoc.exe`
RENDERDOC_OUT_DIR :: "out/captures"

// RENDERDOC_API_1_6_0: function pointers in header order. Only the ones we call are typed.
@(private="file")
RenderDoc_API :: struct {
    GetAPIVersion:              rawptr,
    SetCaptureOptionU32:        rawptr,
    SetCaptureOptionF32:        rawptr,
    GetCaptureOptionU32:        rawptr,
    GetCaptureOptionF32:        rawptr,
    SetFocusToggleKeys:         rawptr,
    SetCaptureKeys:             rawptr,
    GetOverlayBits:             rawptr,
    MaskOverlayBits:            rawptr,
    RemoveHooks:                rawptr,
    UnloadCrashHandler:         rawptr,
    SetCaptureFilePathTemplate: proc "c" (path_template: cstring),
    GetCaptureFilePathTemplate: rawptr,
    GetNumCaptures:             proc "c" () -> u32,
    GetCapture:                 proc "c" (idx: u32, filename: [^]u8, path_length: ^u32, timestamp: ^u64) -> u32,
    TriggerCapture:             rawptr,
    IsTargetControlConnected:   rawptr,
    LaunchReplayUI:             rawptr,
    SetActiveWindow:            rawptr,
    StartFrameCapture:          proc "c" (device: rawptr, window: rawptr),
    IsFrameCapturing:           rawptr,
    EndFrameCapture:            proc "c" (device: rawptr, window: rawptr) -> u32,
    TriggerMultiFrameCapture:   rawptr,
    SetCaptureFileComments:     rawptr,
    DiscardFrameCapture:        rawptr,
    ShowReplayUI:               rawptr,
    SetCaptureTitle:            proc "c" (title: cstring),
}

@(private="file") RENDERDOC_API_VERSION_1_6_0 :: 10600

@(private="file")
renderdoc: struct {
    api:          ^RenderDoc_API,   // nil = RenderDoc not active
    capture_next: bool,             // capture the next frame (set by the `capture` command)
    capturing:    bool,             // between StartFrameCapture and EndFrameCapture this frame
}

renderdoc_init :: proc() {
    module := win32.GetModuleHandleW(win32.L("renderdoc.dll"))   // already injected by RenderDoc?
    if module == nil {
        if !slice.contains(os.args, "--renderdoc") do return
        module = win32.LoadLibraryW(win32.L(RENDERDOC_DLL))
        if module == nil {
            log.errorf("--renderdoc: couldn't load %v", RENDERDOC_DLL)
            return
        }
    }
    get_api := (proc "c" (version: i32, out_api: ^rawptr) -> i32)(win32.GetProcAddress(module, "RENDERDOC_GetAPI"))
    api: rawptr
    if get_api == nil || get_api(RENDERDOC_API_VERSION_1_6_0, &api) != 1 {
        log.error("RenderDoc is loaded but RENDERDOC_GetAPI 1.6.0 failed")
        return
    }
    renderdoc.api = (^RenderDoc_API)(api)

    os.make_directory_all(RENDERDOC_OUT_DIR)
    abs, _ := os.get_absolute_path(RENDERDOC_OUT_DIR + "/blimp", context.temp_allocator)
    renderdoc.api.SetCaptureFilePathTemplate(strings.clone_to_cstring(abs, context.temp_allocator))
    log.infof("RenderDoc active; captures go to %v", RENDERDOC_OUT_DIR)
}

renderdoc_active :: proc() -> bool { return renderdoc.api != nil }

renderdoc_request_capture :: proc() { renderdoc.capture_next = true }

// Around renderer_dx_update: the captured frame is exactly one call of it, submit and present included.
renderdoc_frame_begin :: proc() {
    if renderdoc.api == nil || !renderdoc.capture_next do return
    renderdoc.capture_next = false
    renderdoc.api.StartFrameCapture(nil, nil)   // nil, nil = the active device and window
    renderdoc.capturing = true
}

renderdoc_frame_end :: proc() {
    if !renderdoc.capturing do return
    renderdoc.capturing = false
    if renderdoc.api.EndFrameCapture(nil, nil) == 0 do log.error("RenderDoc: frame capture failed")
}

renderdoc_num_captures :: proc() -> u32 {
    return renderdoc.api != nil ? renderdoc.api.GetNumCaptures() : 0
}

// Path of capture `idx` (0 = oldest), in `allocator`.
renderdoc_capture_path :: proc(idx: u32, allocator := context.temp_allocator) -> (path: string, ok: bool) {
    if renderdoc.api == nil do return
    n: u32
    if renderdoc.api.GetCapture(idx, nil, &n, nil) == 0 do return
    buf := make([]u8, n, allocator)
    renderdoc.api.GetCapture(idx, raw_data(buf), &n, nil)
    return string(cstring(raw_data(buf))), true
}
