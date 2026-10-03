package blimp

import "core:fmt"
import im "lib:odin-imgui"

// Overlays drawn straight on the main window: F3 stats, and recent errors.

// F3: frame time, FPS and GPU time per pass (render_gpu_timer.odin, the latest completed frame), top-right of
// the main window. Drawn on the foreground draw list, so no window can cover it and it takes no input.
ui_draw_stats :: proc() {
    lines := make([dynamic]string, context.temp_allocator)
    dt := timer_delta_sec()
    append(&lines, fmt.tprintf("%.2f ms  %.0f fps", dt * 1000, dt > 0 ? 1 / dt : 0))
    for &t in gpu_timings {
        append(&lines, fmt.tprintf("%*s%s  %.3f ms", t.depth * 2, "", sbuf_str(&t.name), t.ms))
    }

    width: f32 = 0
    for l in lines do width = max(width, im.CalcTextSize(fmt.ctprintf("%s", l)).x)
    line := im.GetTextLineHeight()
    pad := im.GetStyle().WindowPadding
    mv := im.GetMainViewport()
    hi := [2]f32{mv.WorkPos.x + mv.WorkSize.x - pad.x, mv.WorkPos.y + pad.y + f32(len(lines)) * line + pad.y * 2}
    lo := [2]f32{hi.x - width - pad.x * 2, mv.WorkPos.y + pad.y}

    dl := im.GetForegroundDrawList(mv)
    im.DrawList_AddRectFilled(dl, lo, hi, im.GetColorU32ImVec4({0, 0, 0, 0.6}), 4)
    text := im.GetColorU32ImVec4({1, 1, 1, 0.9})
    for l, i in lines do im.DrawList_AddText(dl, lo + pad + {0, f32(i) * line}, text, fmt.ctprintf("%s", l))
}

LOG_OVERLAY_SECONDS :: 8   // how long an error or warning stays on screen
LOG_OVERLAY_LINES   :: 6

// Debug builds: the errors and warnings of the last few seconds, bottom-left of the main window, so a script
// error or a missing asset shows where you're looking instead of only in the console. Foreground draw list,
// like the stats: nothing covers it and it takes no input. `blimpctl log` has the full recent log.
ui_draw_log_overlay :: proc() {
    when !ODIN_DEBUG do return
    now := timer_sec_since_init()
    recent := log_history_recent(LOG_OVERLAY_LINES, .Warning)
    first := len(recent)
    for e, i in recent do if now - e.time < LOG_OVERLAY_SECONDS { first = i; break }
    lines := recent[first:]
    if len(lines) == 0 do return

    line := im.GetTextLineHeight()
    pad := im.GetStyle().WindowPadding
    mv := im.GetMainViewport()
    width: f32 = 0
    for &e in lines do width = max(width, im.CalcTextSize(fmt.ctprintf("%s", sbuf_str(&e.text))).x)
    width = min(width, mv.WorkSize.x - pad.x * 4)
    lo := [2]f32{mv.WorkPos.x + pad.x, mv.WorkPos.y + mv.WorkSize.y - pad.y - f32(len(lines)) * line - pad.y * 2}
    hi := [2]f32{lo.x + width + pad.x * 2, mv.WorkPos.y + mv.WorkSize.y - pad.y}

    dl := im.GetForegroundDrawList(mv)
    im.DrawList_AddRectFilled(dl, lo, hi, im.GetColorU32ImVec4({0, 0, 0, 0.7}), 4)
    for &e, i in lines {
        col: [4]f32 = e.level >= .Error ? {1, 0.45, 0.4, 1} : {1, 0.8, 0.35, 1}
        im.DrawList_AddText(dl, lo + pad + {0, f32(i) * line}, im.GetColorU32ImVec4(col), fmt.ctprintf("%s", sbuf_str(&e.text)))
    }
}
