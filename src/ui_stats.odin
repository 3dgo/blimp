package blimp

import "core:fmt"
import im "lib:odin-imgui"

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
