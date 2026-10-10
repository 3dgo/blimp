package blimp

import "base:runtime"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:path/filepath"
import "common"
import hm "core:container/handle_map"

// A scene is the on-disk (INI) form of a level: a [world] section (World_Settings), then one [entity]
// section per entity. It reuses the structs directly via reflection (the codec in serialize.odin) — no
// parallel DTO — and per-field backtick tags control it: a field tagged `noserialize` is skipped (e.g.
// the runtime handle). The [entity] block is also the clipboard payload and the template format
// (entity.odin), so loading is additive: it merges the text's entities into the world.

// The extension that makes a file a level (assets_engine/templates.level, the starting lights and
// cameras, is one too: open it and copy from it).
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

// Writes a new level at `path`: default world settings, no entities. Refuses to overwrite a file
// that's already there. Creates missing folders.
scene_create :: proc(path: string) -> bool {
    if os.exists(path) {
        log.errorf("Can't create scene '%v': the file already exists", path)
        return false
    }
    os.make_directory_all(filepath.dir(path))

    b: strings.Builder
    strings.builder_init(&b, context.temp_allocator)
    strings.write_string(&b, "[world]\n")
    serialize_struct(&b, WORLD_SETTINGS_DEFAULT)
    if err := os.write_entire_file(path, b.buf[:]); err != nil {
        log.errorf("Failed to write scene '%v': %v", path, err)
        return false
    }
    log.infof("Created scene '%v'", path)
    return true
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
        strings.write_string(&b, entity_to_text(e, context.temp_allocator))
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

// Additive: parses [entity] blocks from `text`, adding one entity per block (world_add). Optionally
// collects the created handles (paste selects them). Backs file load and clipboard paste —
// the block format is identical.
scene_load_from_text :: proc(world: ^World, text: string, out_handles: ^[dynamic]Entity_Handle = nil) -> (count: int) {
    e: Entity
    in_entity := false
    flush :: proc(world: ^World, e: Entity, out_handles: ^[dynamic]Entity_Handle, count: ^int) {
        h, ok := world_add(world, e)
        if !ok do return
        if out_handles != nil do append(out_handles, h)
        count^ += 1
    }
    r := Ini_Reader{text = text}
    for line in ini_next(&r) {
        if line.header {
            if in_entity do flush(world, e, out_handles, &count)
            in_entity = line.section == ENTITY_SECTION
            e = entity_default()
        } else if in_entity {
            deserialize_field(&e, line.key, line.value)
        }
    }
    if in_entity do flush(world, e, out_handles, &count)
    return
}

// Reads the [world] section (World_Settings) into `world`. Only scene loading does this — pasted
// clipboard text goes through scene_load_from_text, which skips every section but [entity], so a
// paste never touches a world's settings. A scene without the section keeps the defaults.
scene_load_world_settings :: proc(world: ^World, text: string) {
    ini_read_section(text, "world", world.settings)
    asset_intern_keys(world.settings)   // its keys (sky.texture) outlive the text
}

