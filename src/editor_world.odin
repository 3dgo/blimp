package blimp

// The editor's side of a World: which entity is active, where a Shift+click range starts, and whether
// there are unsaved changes. Kept off World so the runtime's world is only what the game needs; the
// same pattern as Editor_View for a Render_View. One per world, created on first use, freed when the
// world closes (editor_world_forget from app_process_closes).
//
// Selection membership itself is the entity's `selected` field (editor_selection.odin), the one piece
// of editor state on a core struct: that way undo snapshots carry it and delete/paste need no bookkeeping.
Editor_World :: struct {
    world: ^World,

    active:        Entity_Handle,   // the selected entity the inspector shows and the gizmo pivots on (editor_selection.odin)
    select_anchor: Entity_Handle,   // entity list: where a Shift+click range starts (the last plain or Ctrl click)

    // Unsaved-changes tracking. Every edit goes through undo_push, which gives the world a fresh state
    // id; undo/redo restore the id along with the snapshot. So the world is dirty exactly when its state
    // isn't the one last saved — undoing back to the saved state makes it clean again.
    state_id:       u64,
    saved_state_id: u64,
}

@(private="file") editor_worlds: [dynamic]^Editor_World   // individually allocated, so pointers stay put
@(private="file") world_state_counter: u64                // state ids are unique across all worlds

// The editor state for `w`, created on first use.
editor_world :: proc(w: ^World) -> ^Editor_World {
    for ew in editor_worlds do if ew.world == w do return ew
    ew := new(Editor_World)
    ew.world = w
    append(&editor_worlds, ew)
    return ew
}

editor_world_forget :: proc(w: ^World) {
    for ew, i in editor_worlds {
        if ew.world != w do continue
        free(ew)
        unordered_remove(&editor_worlds, i)
        return
    }
}

editor_worlds_shutdown :: proc() {
    for ew in editor_worlds do free(ew)
    delete(editor_worlds)
}

// Play: the copy starts with the level's active entity and anchor (the selection flags came with the
// entities).
editor_world_copy :: proc(from, to: ^World) {
    src, dst := editor_world(from), editor_world(to)
    dst.active, dst.select_anchor = src.active, src.select_anchor
}

// The world is about to change (called by undo_push): it gets a state id it has never had.
world_new_state :: proc(w: ^World) {
    world_state_counter += 1
    editor_world(w).state_id = world_state_counter
}

// Unsaved changes. Kits can't be saved, so they're never dirty (closing one never prompts); nor can
// play worlds (no save_path).
world_dirty :: proc(w: ^World) -> bool {
    ew := editor_world(w)
    return w.save_path != "" && ew.state_id != ew.saved_state_id
}

// Writes a scene world back to the .level it was opened from. Kits and play worlds (no save_path) can't
// be saved: the running game's state is never written.
world_save :: proc(w: ^World) -> bool {
    if w.save_path == "" || !scene_save(w, w.save_path) do return false
    ew := editor_world(w)
    ew.saved_state_id = ew.state_id
    return true
}
