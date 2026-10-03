package blimp

import "core:log"
import "core:sync"

// The last LOG_HISTORY_MAX log lines, kept in memory beside the console: a logger that app.odin runs next
// to the console one. Read by the on-screen error overlay (ui_stats.odin) and `blimpctl log`. Any thread
// may log (the baker's workers), so the ring takes a lock.

LOG_HISTORY_MAX :: 256

Log_Entry :: struct {
    level: log.Level,
    time:  f64,       // timer_sec_since_init when logged
    text:  sbuf256,   // the message, cut to fit
}

@(private="file")
log_history: struct {
    lock:    sync.Mutex,
    entries: [LOG_HISTORY_MAX]Log_Entry,
    count:   int,   // lines ever logged; the newest is entries[(count - 1) % LOG_HISTORY_MAX]
}

log_history_logger :: proc() -> log.Logger {
    return {procedure = log_history_proc, lowest_level = .Info}
}

@(private="file")
log_history_proc :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
    sync.guard(&log_history.lock)
    e := &log_history.entries[log_history.count % LOG_HISTORY_MAX]
    e.level, e.time = level, timer_sec_since_init()
    k := min(len(text), cap(e.text))
    for k > 0 && k < len(text) && (text[k] & 0xC0) == 0x80 do k -= 1   // don't split a UTF-8 character
    sbuf_set(&e.text, text[:k])
    log_history.count += 1
}

// The newest `n` lines at or above `min_level` (oldest first), copied with `allocator`.
log_history_recent :: proc(n: int, min_level := log.Level.Info, allocator := context.temp_allocator) -> []Log_Entry {
    sync.guard(&log_history.lock)
    out := make([dynamic]Log_Entry, 0, n, allocator)
    first := max(log_history.count - LOG_HISTORY_MAX, 0)
    for i := log_history.count - 1; i >= first && len(out) < n; i -= 1 {
        e := log_history.entries[i % LOG_HISTORY_MAX]
        if e.level >= min_level do append(&out, e)
    }
    for i in 0 ..< len(out) / 2 do out[i], out[len(out) - 1 - i] = out[len(out) - 1 - i], out[i]
    return out[:]
}
