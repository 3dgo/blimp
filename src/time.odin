package blimp
import "core:time"

// Engine clocks. Frame-stable ones (delta, since start, frame index) are sampled once in
// timer_frame_begin, so every system in a frame reads the same values; timer_sec_since_init is live
// wall-clock time, for timeouts and debouncing. Game time is per play world (World.time, world_play.odin).
Timer :: struct {
    init_tick:   time.Tick,
    start_tick:  time.Tick,
    frame_tick:  time.Tick,   // when the current frame began
    delta_sec:   f64,         // previous frame's full period, start to start
    frame_index: u64,         // frames begun since timer_start
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
    g_timer.frame_index += 1
}

// Live: now, not the frame's start.
timer_sec_since_init :: proc() -> f64 {
    return time.duration_seconds(time.tick_since(g_timer.init_tick))
}

// The current frame's start, in seconds since timer_start: light flicker and anything else animated by
// wall-clock time reads this, so it agrees across the frame.
timer_sec_since_start :: proc() -> f64 {
    return time.duration_seconds(time.tick_diff(g_timer.start_tick, g_timer.frame_tick))
}

timer_delta_sec :: proc() -> f64 {
    return g_timer.delta_sec
}

timer_frame_index :: proc() -> u64 {
    return g_timer.frame_index
}
