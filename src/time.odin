package blimp
import "core:time"

Timer :: struct {
    init_tick:  time.Tick,
    start_tick: time.Tick,
    frame_tick: time.Tick,   // when the current frame began
    delta_sec:  f64,         // previous frame's full period, start to start
}
g_timer: Timer

timer_init :: proc() {
    g_timer.init_tick = time.tick_now()
}

timer_start :: proc() {
    g_timer.start_tick = time.tick_now()
    g_timer.frame_tick = g_timer.start_tick
}

// Once per frame, first thing in the main loop. Measuring start to start makes the delta the whole
// frame — input, update, UI, rendering, and the fence/present waits — and every caller in the
// frame reads the same value.
timer_frame_begin :: proc() {
    now := time.tick_now()
    g_timer.delta_sec  = time.duration_seconds(time.tick_diff(g_timer.frame_tick, now))
    g_timer.frame_tick = now
}

timer_sec_since_init :: proc() -> f64 {
    return time.duration_seconds(time.tick_since(g_timer.init_tick))
}

timer_sec_since_start :: proc() -> f64 {
    return time.duration_seconds(time.tick_since(g_timer.start_tick))
}

timer_delta_sec :: proc() -> f64 {
    return g_timer.delta_sec
}
