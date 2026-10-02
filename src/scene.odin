package blimp

import "base:runtime"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:path/filepath"
import "common"
import vmem "core:mem/virtual"
import hm "core:container/handle_map"

// A scene is the on-disk (INI) form of a level or sub-level. It reuses the Entity struct
// directly via reflection (the generic codec in serialize.odin) — no parallel DTO — and
// per-field backtick tags control it: a field tagged `noserialize` is skipped (e.g. the
// runtime handle). Loading is additive: it merges the scene's entities into the current world.
//
// Format: one `[entity]` section per entity, `field = value` lines. Vectors and quaternions
// are comma-separated floats. The same block format is the clipboard payload (see world_entity.odin).

// The extension that makes a file a level. Other files in the same format (the entity templates)
// use another extension, so they never show up as levels.
LEVEL_EXT :: ".level"

// Every scene file the editor can open: LEVEL_EXT files under assets/ or assets_engine/.
// Appends project-relative paths, cloned with `allocator`.
scene_find_files :: proc(out: ^[dynamic]string, allocator: runtime.Allocator) {
    files := make([dynamic]os.File_Info, context.temp_allocator)
    _ = common.get_all_files("./assets", &files, context.temp_allocator)
    _ = common.get_all_files("./assets_engine", &files, context.temp_allocator)

    for fi in files {
        if strings.to_lower(filepath.ext(fi.fullpath), context.temp_allocator) != LEVEL_EXT do continue
        append(out, asset_key(fi.fullpath, allocator))
    }
    slice.sort(out[:])
}

scene_save :: proc(world: ^World, path: string) -> bool {
    b: strings.Builder
    strings.builder_init(&b, context.temp_allocator)

    // World settings first, then the entities.
    strings.write_string(&b, "[world]\n")
    serialize_struct(&b, world.settings)
    strings.write_byte(&b, '\n')

    count := 0
    it := hm.iterator_make(&world.entities)
    for e, _ in hm.iterate(&it) {
        strings.write_string(&b, "[entity]\n")
        serialize_struct(&b, e^)
        strings.write_byte(&b, '\n')
        count += 1
    }

    if err := os.write_entire_file(path, b.buf[:]); err != nil {
        log.errorf("Failed to write scene '%v': %v", path, err)
        return false
    }
    log.infof("Saved scene '%v' (%v entities)", path, count)
    return true
}

scene_load :: proc(world: ^World, path: string) -> bool {
    data, rerr := os.read_entire_file(path, context.temp_allocator)
    if rerr != nil {
        log.errorf("Failed to read scene '%v': %v", path, rerr)
        return false
    }

    scene_load_world_settings(world, string(data))
    count := scene_load_from_text(world, string(data))
    probe_grid_load(world, probes_path(path))
    log.infof("Loaded scene '%v' (%v entities)", path, count)
    return true
}

// Additive: parses [entity] blocks from `text`, creating one new entity per block. Optionally
// collects the created handles (Ctrl+V uses this to select the paste). Backs both file load and
// clipboard paste — the block format is identical.
scene_load_from_text :: proc(world: ^World, text: string, out_handles: ^[dynamic]Entity_Handle = nil, skip_tags: []string = {}) -> (count: int) {
    e: Entity
    in_entity := false
    txt := text
    for line in strings.split_lines_iterator(&txt) {
        trimmed := strings.trim_space(line)
        if len(trimmed) == 0 || trimmed[0] == '#' || trimmed[0] == ';' {
            continue
        }

        if trimmed[0] == '[' && trimmed[len(trimmed) - 1] == ']' {
            if in_entity {
                entity_intern_keys(&e)   // normalize to the interned asset keys
                entity_make_name_unique(world, &e)   // names are unique per world (pasting "car" again gives "car_1")
                h := hm.add(&world.entities, e)            // flush the entity we just finished reading
                if out_handles != nil do append(out_handles, h)
                count += 1
            }
            e = Entity{}
            entity_apply_defaults(&e)   // so a scene missing a (newly-added) field gets its default, not zero
            in_entity = strings.trim_space(trimmed[1:len(trimmed) - 1]) == "entity"
            continue
        }

        if !in_entity do continue

        eq := strings.index_byte(trimmed, '=')
        if eq < 0 do continue
        key := strings.trim_space(trimmed[:eq])
        val := strings.trim_space(trimmed[eq + 1:])
        deserialize_field(&e, key, val, vmem.arena_allocator(&world.arena), skip_tags)
    }
    if in_entity {
        entity_intern_keys(&e)
        entity_make_name_unique(world, &e)
        h := hm.add(&world.entities, e)
        if out_handles != nil do append(out_handles, h)
        count += 1
    }

    return
}

// Reads the [world] section (World_Settings) into `world`. Only scene loading does this — pasted
// clipboard text goes through scene_load_from_text, which skips every section but [entity], so a
// paste never touches a world's settings. A scene without the section keeps the defaults.
scene_load_world_settings :: proc(world: ^World, text: string) {
    ini_read_section(text, "world", world.settings, vmem.arena_allocator(&world.arena))
}
