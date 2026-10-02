package blimp

import hm "core:container/handle_map"

// Undo is whole-world snapshots: before any edit, copy the world's entity map. The map is a fixed-size
// value (Static_Handle_Map) of plain-data entities — names are inline sbufs, `model` points at an
// interned asset key — so the copy is one struct assignment, and restoring it brings back every
// entity with its exact handle (generations and free list included). No per-operation logic: move,
// paste, delete, inspector edits all just call undo_push first.
//
// Rule this relies on: anything an Entity points into (arena strings, later slices) is never mutated
// in place — replace it instead — because snapshots share it.
//
// One global history across all open worlds — Ctrl+Z undoes the latest change wherever it was made.
// Each entry remembers its world; closing a world drops its entries (a play world's go when it stops).
Undo_Entry :: struct {
    world:    ^World,
    entities: ^Entity_Handle_Map,   // heap copy: at MAX_ENTITIES it's ~600 KB, so the stacks move pointers
    active:   Entity_Handle,
    state_id: u64,                  // the world's state id for this snapshot (unsaved-changes tracking)
    settings: World_Settings,       // the [world] section, which undo covers too
}
undo_stack: [dynamic]Undo_Entry   // editor state → general heap (CLAUDE.md)
redo_stack: [dynamic]Undo_Entry

UNDO_MAX_STEPS :: 64   // oldest steps fall off; each costs size_of(Entity_Handle_Map)

// Call BEFORE changing anything in `w`. A new edit discards the redo history. Play worlds keep no undo
// (world_play.odin): their edits are thrown away on Stop anyway, so nothing is recorded (returns false).
undo_push :: proc(w: ^World) -> (recorded: bool) {
    if w.play_source != nil do return false
    if len(undo_stack) >= UNDO_MAX_STEPS {
        undo_entry_free(undo_stack[0])
        ordered_remove(&undo_stack, 0)
    }
    append(&undo_stack, undo_capture(w))
    world_new_state(w)   // the edit that follows is a state the world has never been in
    undo_clear_stack(&redo_stack)
    return true
}

// For an edit that has already happened to one entity (detected after the fact — gizmo drag,
// inspector widgets): snapshot the world as it is now, but with that entity as it was.
undo_push_edited :: proc(w: ^World, handle: Entity_Handle, before: Entity) {
    if !undo_push(w) do return
    if e, ok := hm.get(undo_stack[len(undo_stack) - 1].entities, handle); ok do e^ = before
}

// For a world-settings edit that has already happened (the settings window): snapshot the world as
// it is now, but with the settings as they were.
undo_push_settings_edited :: proc(w: ^World, before: World_Settings) {
    if !undo_push(w) do return
    undo_stack[len(undo_stack) - 1].settings = before
}

undo :: proc() {
    if len(undo_stack) == 0 || undo_locked(undo_stack[len(undo_stack) - 1]) do return
    entry := pop(&undo_stack)
    append(&redo_stack, undo_capture(entry.world))
    undo_restore(entry)
}

redo :: proc() {
    if len(redo_stack) == 0 || undo_locked(redo_stack[len(redo_stack) - 1]) do return
    entry := pop(&redo_stack)
    append(&undo_stack, undo_capture(entry.world))
    undo_restore(entry)
}

// Abandons the edit in progress: restores the latest snapshot without making it redoable (Esc
// during a gizmo drag).
undo_revert_last :: proc() {
    if len(undo_stack) == 0 || undo_locked(undo_stack[len(undo_stack) - 1]) do return
    undo_restore(pop(&undo_stack))
}

@(private="file")
undo_capture :: proc(w: ^World) -> Undo_Entry {
    snapshot := new(Entity_Handle_Map)
    snapshot^ = w.entities
    return {world = w, entities = snapshot, active = w.active, state_id = w.state_id, settings = w.settings}
}

// A level's steps wait while it's playing: its views show the play world, so undoing into the level
// would change something you can't see (world_play.odin).
@(private="file")
undo_locked :: proc(entry: Undo_Entry) -> bool {
    return entry.world.play_world != nil
}

// Restores and frees the entry.
@(private="file")
undo_restore :: proc(entry: Undo_Entry) {
    entry.world.entities = entry.entities^
    entry.world.active = entry.active
    entry.world.state_id = entry.state_id
    entry.world.settings = entry.settings
    undo_entry_free(entry)
}

@(private="file")
undo_entry_free :: proc(entry: Undo_Entry) { free(entry.entities) }

@(private="file")
undo_clear_stack :: proc(stack: ^[dynamic]Undo_Entry) {
    for entry in stack do undo_entry_free(entry)
    clear(stack)
}

// Drops every entry for `w` — called as the world closes, so no entry outlives its world.
undo_forget_world :: proc(w: ^World) {
    for stack in ([]^[dynamic]Undo_Entry{&undo_stack, &redo_stack}) {
        for i := len(stack) - 1; i >= 0; i -= 1 {
            if stack[i].world != w do continue
            undo_entry_free(stack[i])
            ordered_remove(stack, i)
        }
    }
}

undo_shutdown :: proc() {
    undo_clear_stack(&undo_stack)
    undo_clear_stack(&redo_stack)
    delete(undo_stack)
    delete(redo_stack)
}
