package blimp

import "vendor:directx/d3d12"
import "dx"

// GPU timestamps per pass, on the gfx queue. Each frame slot owns a range of a timestamp query
// heap; a scope writes a timestamp at its begin and end, the frame resolves its range into a
// persistently mapped readback buffer, and the results are read when that slot comes round again
// (right after its fence wait), so the CPU never stalls for them. `gpu_timings` holds the latest
// completed frame — shown in the FPS overlay and returned by `blimpctl timings`.
//
//   s := gpu_timer_begin(cmd, "ui")
//   ...record the pass...
//   gpu_timer_end(cmd, s)
//
// Scopes may nest (the whole frame is one); they're listed in begin order.
GPU_TIMER_MAX_SCOPES :: 32   // per frame; further scopes are dropped (and not timed)

Gpu_Timing :: struct {
    name:  sbuf64,
    depth: int,   // nesting level, for indentation
    ms:    f32,
}

@(private="file")
Gpu_Timer_Scope :: struct {
    name:  sbuf64,
    depth: int,
    begin: u32,   // query indices within this slot's range
    end:   u32,
}

@(private="file")
gpu_timer: struct {
    heap:     ^d3d12.IQueryHeap,
    readback: ^d3d12.IResource,
    ticks:    [^]u64,   // the readback buffer, mapped for the engine's lifetime
    freq:     u64,      // gfx queue timestamp ticks per second
    scopes:   [FRAMES_IN_FLIGHT][dynamic; GPU_TIMER_MAX_SCOPES]Gpu_Timer_Scope,
    queries:  [FRAMES_IN_FLIGHT]u32,   // queries written this frame in each slot
    depth:    int,                     // currently open scopes (recording frame only)
}

gpu_timings: [dynamic; GPU_TIMER_MAX_SCOPES]Gpu_Timing   // the latest completed frame

@(private="file") QUERIES_PER_SLOT :: 2 * GPU_TIMER_MAX_SCOPES

gpu_timer_init :: proc() {
    rc := renderer_dx.render_context
    count := u32(QUERIES_PER_SLOT * FRAMES_IN_FLIGHT)
    hr := rc.device->CreateQueryHeap(&d3d12.QUERY_HEAP_DESC{Type = .TIMESTAMP, Count = count}, d3d12.IQueryHeap_UUID, (^rawptr)(&gpu_timer.heap))
    dx.check_dx(hr, "Failed to create timestamp query heap")
    gpu_timer.readback = dx.readback_buffer_create(rc, u64(count) * size_of(u64))
    hr = gpu_timer.readback->Map(0, &d3d12.RANGE{0, uint(count) * size_of(u64)}, (^rawptr)(&gpu_timer.ticks))
    dx.check_dx(hr, "Failed to map timestamp readback")
    hr = renderer_dx.cmd_queue_gfx.handle->GetTimestampFrequency(&gpu_timer.freq)
    dx.check_dx(hr, "Failed to get timestamp frequency")
}

gpu_timer_shutdown :: proc() {
    gpu_timer.readback->Unmap(0, &d3d12.RANGE{})
    gpu_timer.readback->Release()
    gpu_timer.heap->Release()
}

// Call right after the slot's fence wait: its previous frame's timestamps are now in the readback
// buffer. Publishes them to gpu_timings and frees the slot's range for this frame.
gpu_timer_frame_begin :: proc(slot: u64) {
    base := u32(slot) * QUERIES_PER_SLOT
    if len(gpu_timer.scopes[slot]) > 0 {
        clear(&gpu_timings)
        for s in gpu_timer.scopes[slot] {
            ticks := gpu_timer.ticks[base + s.end] - gpu_timer.ticks[base + s.begin]
            append(&gpu_timings, Gpu_Timing{name = s.name, depth = s.depth, ms = f32(f64(ticks) * 1000 / f64(gpu_timer.freq))})
        }
    }
    clear(&gpu_timer.scopes[slot])
    gpu_timer.queries[slot] = 0
    gpu_timer.depth = 0
}

// Returns the scope index for gpu_timer_end; -1 when the frame is out of scopes.
gpu_timer_begin :: proc(cmd: dx.Command_List, name: string) -> int {
    slot := renderer_dx.frame_val % FRAMES_IN_FLIGHT
    scopes := &gpu_timer.scopes[slot]
    if len(scopes) == GPU_TIMER_MAX_SCOPES do return -1
    q := gpu_timer.queries[slot]
    gpu_timer.queries[slot] += 2   // reserve begin + end, so scopes can nest
    cmd.handle->EndQuery(gpu_timer.heap, .TIMESTAMP, u32(slot) * QUERIES_PER_SLOT + q)
    s := Gpu_Timer_Scope{depth = gpu_timer.depth, begin = q, end = q + 1}
    sbuf_set(&s.name, name)
    append(scopes, s)
    gpu_timer.depth += 1
    return len(scopes) - 1
}

gpu_timer_end :: proc(cmd: dx.Command_List, scope: int) {
    if scope < 0 do return
    slot := renderer_dx.frame_val % FRAMES_IN_FLIGHT
    cmd.handle->EndQuery(gpu_timer.heap, .TIMESTAMP, u32(slot) * QUERIES_PER_SLOT + gpu_timer.scopes[slot][scope].end)
    gpu_timer.depth -= 1
}

// Before the gfx list closes: copy this frame's timestamps to the readback buffer.
gpu_timer_frame_resolve :: proc(cmd: dx.Command_List) {
    slot := renderer_dx.frame_val % FRAMES_IN_FLIGHT
    n := gpu_timer.queries[slot]
    if n == 0 do return
    base := u32(slot) * QUERIES_PER_SLOT
    cmd.handle->ResolveQueryData(gpu_timer.heap, .TIMESTAMP, base, n, gpu_timer.readback, u64(base) * size_of(u64))
}

