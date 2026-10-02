package blimp

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import im "lib:odin-imgui"

// The Templates window (Show menu): one entry per [entity] block in TEMPLATES_PATH — lights, cameras,
// anything worth starting from. Clicking one adds it to the active world at the paste point, like a
// one-block Ctrl+V that keeps the template's rotation and scale. The file is in the level/clipboard
// format but not a .level, so the Worlds window doesn't list it; Edit Templates opens it as a world.

TEMPLATES_PATH :: "assets_engine/entity_templates.ini"
TEMPLATES_WINDOW_SIZE :: [2]f32{260, 320}   // first-open size (× display scale)

Entity_Template :: struct {
    name: string,   // the block's name field
    icon: string,   // entity_icon, "" for none
    text: string,   // the [entity] block, slicing templates_ui.text
}

@(private="file")
templates_ui: struct {
    text:   string,                     // the whole file (perm)
    list:   [dynamic]Entity_Template,   // perm
    loaded: bool,
}

ui_draw_templates :: proc() {
    if !ui.show_templates do return
    if !templates_ui.loaded do templates_load()

    s := app.dispaly_scale
    im.SetNextWindowSize({TEMPLATES_WINDOW_SIZE.x * s, TEMPLATES_WINDOW_SIZE.y * s}, .FirstUseEver)
    if !im.Begin(tr(.Win_Templates), &ui.show_templates) { im.End(); return }
    defer im.End()

    if im.SmallButton(fmt.ctprintf("%s %s", ICON_RENAME, tr(.Btn_Edit_Templates))) {
        if open := world_find_open(TEMPLATES_PATH); open != nil do ui_world_focus(open)
        else do world_open_scene(TEMPLATES_PATH)
    }
    im.SameLine()
    if im.SmallButton(fmt.ctprintf("%s", ICON_REFRESH)) do templates_load()   // after saving edits to the file
    im.SetItemTooltip("%s", tr(.Btn_Refresh))
    im.Separator()

    w := active_world()
    if w == nil do text_dim_wrapped(tr(.Templates_No_World))
    else do im.TextDisabled("%s", tr(.Templates_Hint))

    im.BeginDisabled(w == nil)
    for t, i in templates_ui.list {
        im.PushIDInt(i32(i))
        if ui_icon_selectable("##t", t.icon, t.name, false) do templates_add(w, t, paste_target_point(editor_view(active_view)))
        im.PopID()
    }
    im.EndDisabled()
    if len(templates_ui.list) == 0 do im.TextDisabled("%s", tr(.Worlds_None))
}

// Adds `t` to `w` at `pos` and selects it. Unlike a one-block paste it keeps the block's rotation and
// scale (a spot light starts pointing down); only the position comes from the paste point.
@(private="file")
templates_add :: proc(w: ^World, t: Entity_Template, pos: vec3) {
    undo_push(w)
    handles := make([dynamic]Entity_Handle, context.temp_allocator)
    scene_load_from_text(w, t.text, &handles)
    selection_clear(w)
    for h in handles {
        e := entity_get(w, h) or_continue
        e.position = pos
        selection_set(w, h, true)
    }
}

// (Re)reads TEMPLATES_PATH and splits it at its [entity] headers. Each block runs to the next header
// of any section; scene_load_from_text ignores anything that isn't an [entity].
@(private="file")
templates_load :: proc() {
    templates_free()
    templates_ui.loaded = true

    data, err := os.read_entire_file(TEMPLATES_PATH, app.allocators.perm)
    if err != nil {
        log.errorf("Failed to read entity templates '%v': %v", TEMPLATES_PATH, err)
        return
    }
    templates_ui.text = string(data)

    start := -1   // byte offset of the current [entity] header, -1 outside one
    txt := templates_ui.text
    for line in strings.split_lines_iterator(&txt) {
        line_start := int(uintptr(raw_data(line)) - uintptr(raw_data(templates_ui.text)))   // lines slice the text (CRLF-safe)
        t := strings.trim_space(line)
        if len(t) < 2 || t[0] != '[' || t[len(t)-1] != ']' do continue
        if start >= 0 do templates_append(templates_ui.text[start:line_start])
        start = strings.trim_space(t[1:len(t)-1]) == "entity" ? line_start : -1
    }
    if start >= 0 do templates_append(templates_ui.text[start:])
}

ui_templates_shutdown :: proc() {
    templates_free()
    delete(templates_ui.list)
}

@(private="file")
templates_free :: proc() {
    for t in templates_ui.list {
        delete(t.name, app.allocators.perm)
        delete(t.icon, app.allocators.perm)
    }
    clear(&templates_ui.list)
    delete(templates_ui.text, app.allocators.perm)
    templates_ui.text = ""
}

@(private="file")
templates_append :: proc(block: string) {
    e: Entity
    entity_apply_defaults(&e)
    entity_apply_text(&e, block, context.temp_allocator)
    icon, _ := entity_icon(&e)
    append(&templates_ui.list, Entity_Template{
        name = strings.clone(sbuf_str(&e.name), app.allocators.perm),
        icon = strings.clone(icon, app.allocators.perm),
        text = block,
    })
}
