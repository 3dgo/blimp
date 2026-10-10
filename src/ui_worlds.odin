package blimp

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import im "lib:odin-imgui"

// The Worlds window — the first thing you see. Top: a title, a search box, then what you can open —
// scenes and kits, collapsible sections of two-line rows (icon, file name, folder dimmed underneath),
// scrolling in whatever height is left. Bottom: a separate panel of what's open right now — a status
// strip, not a third list — with compact rows and per-world + / × buttons; hidden when nothing is open.
//
// Clicking a scene or kit opens it — or, if it's already open, brings its window forward instead of
// opening a second copy (two copies of a scene would both save to the same file). Right-clicking any
// row offers Show in Explorer.
@(private="file")
worlds_ui: struct {
    filter: [128]u8,   // search box text (NUL-terminated); filters scenes and kits by path
    new_name: [64]u8,  // the New Scene popup's name box (NUL-terminated)
    new_pressed: bool, // the Scenes header's + was clicked this frame
}

// Where New Scene puts a level: the name typed, under this folder, plus LEVEL_EXT.
NEW_SCENE_DIR :: "assets/scenes/"

WORLDS_TITLE_SCALE    :: 1.5   // the "Blimp" heading, × the UI font size
WORLDS_OPEN_MAX_SHARE :: 0.4   // the open-worlds panel grows with its rows up to this share of the height, then scrolls

ui_draw_worlds :: proc() {
    if !im.Begin(tr(.Win_Worlds), &ui.show_worlds) { im.End(); return }
    defer im.End()

    // Header: title, a one-line hint, the search box.
    im.PushFontFloat(nil, ui_font_size() * WORLDS_TITLE_SCALE)
    im.TextUnformatted("Blimp")
    im.PopFont()
    text_dim_wrapped(tr(.Worlds_Subtitle))
    im.Spacing()
    im.SetNextItemWidth(-1)
    im.InputTextWithHint("##worlds_filter", fmt.ctprintf("%s  %s", ICON_SEARCH, tr(.Worlds_Search)), cstring(&worlds_ui.filter[0]), len(worlds_ui.filter))
    filter := string(cstring(&worlds_ui.filter[0]))   // search_matches ignores case

    // What you can open, in the height the open-worlds panel leaves.
    open_h := len(worlds) > 0 ? worlds_open_panel_height() : 0
    if im.BeginChild("##browse", {0, -open_h}) {
        worlds_browse(filter)
    }
    im.EndChild()

    if len(worlds) > 0 do worlds_open_panel()
}

// Scenes, characters and kits.
@(private="file")
worlds_browse :: proc(filter: string) {
    // Scenes: .level files under assets/ and assets_engine/ (rescanned on refresh).
    scenes_open := worlds_section(ICON_SCENE, tr(.Worlds_Scenes), len(ui.scene_paths), "scenes", true)
    if worlds_ui.new_pressed do im.OpenPopup("##new_scene")
    worlds_new_scene_popup()
    if worlds_refresh_clicked() || !ui.scene_paths_scanned {
        for p in ui.scene_paths do delete(p, app.allocators.perm)
        clear(&ui.scene_paths)
        scene_find_files(&ui.scene_paths, app.allocators.perm)
        ui.scene_paths_scanned = true
    }
    if scenes_open {
        im.PushID("scenes")   // each section its own ID scope: row i of one mustn't collide with row i of another
        defer im.PopID()
        shown := 0
        for path, i in ui.scene_paths {
            if !search_matches(path, filter) do continue
            shown += 1
            im.PushIDInt(i32(i))
            open := world_find_open(path)
            if worlds_row(ICON_SCENE, filepath.base(path), filepath.dir(path), open != nil ? tr(.Worlds_Opened_Tag) : nil) {
                if open != nil do ui_world_focus(open)
                else do app_open_scene(path)
            }
            worlds_row_menu(path)
            im.PopID()
        }
        if shown == 0 do im.TextDisabled("%s", tr(.Worlds_None))
    }

    // glTF files, loaded at startup: characters (a skinned model in them), then the other kits.
    worlds_kits(ICON_CHARACTER, tr(.Worlds_Characters), "characters", true, filter)
    worlds_kits(ICON_KIT, tr(.Worlds_Kits), "kits", false, filter)
}

// One section of glTF files: the kits that are characters, or the ones that aren't.
@(private="file")
worlds_kits :: proc(icon: string, title: cstring, id: string, characters: bool, filter: string) {
    count := 0
    for kit in asset_system.kits do if kit.character == characters do count += 1
    if !worlds_section(icon, title, count, id) do return
    im.PushID(fmt.ctprintf("%s", id))
    defer im.PopID()
    shown := 0
    for &kit, i in asset_system.kits {
        if kit.character != characters || !search_matches(kit.path, filter) do continue
        shown += 1
        im.PushIDInt(i32(i))
        open := world_find_open(kit.path)
        if worlds_row(icon, filepath.base(kit.path), filepath.dir(kit.path), open != nil ? tr(.Worlds_Opened_Tag) : nil) {
            if open != nil do ui_world_focus(open)
            else do app_open_kit(&kit)
        }
        worlds_row_menu(kit.path)
        im.PopID()
    }
    if shown == 0 do im.TextDisabled("%s", tr(.Worlds_None))
}

// Fits its rows, up to WORLDS_OPEN_MAX_SHARE of the height left; past that the panel scrolls.
@(private="file")
worlds_open_panel_height :: proc() -> f32 {
    style := im.GetStyle()
    rows := f32(worlds_level_count()) * (im.GetFrameHeight() + style.ItemSpacing.y)
    h := im.GetTextLineHeightWithSpacing() + rows + style.WindowPadding.y * 2 + style.ItemSpacing.y * 2   // slack: a pixel short would add a scrollbar
    return min(h, im.GetContentRegionAvail().y * WORLDS_OPEN_MAX_SHARE)
}

// What's open now: a bordered panel on a slightly lighter background, compact one-line rows.
// Click a row to bring that world forward; + adds a viewport, × closes it (asking first if unsaved).
@(private="file")
worlds_open_panel :: proc() {
    im.PushStyleColorImVec4(.ChildBg, {0.145, 0.145, 0.149, 1})   // VS Code's side-panel grey
    defer im.PopStyleColor()
    if im.BeginChild("##open_worlds", {0, 0}, {.Borders}) {
        im.TextDisabled("%s  %s  (%d)", fmt.ctprintf("%s", ICON_GLOBAL), tr(.Worlds_Open), worlds_level_count())
        im.PushID("open")
        for w, i in worlds {
            if w.play_source != nil do continue   // a play world shows as its level's "playing" tag
            im.PushIDInt(i32(i))
            worlds_open_row(w)
            im.PopID()
        }
        im.PopID()
    }
    im.EndChild()
}

@(private="file")
worlds_open_row :: proc(w: ^World) {
    style := im.GetStyle()
    h := im.GetFrameHeight()
    im.SetNextItemAllowOverlap()   // the + / × buttons sit on top of it
    if im.Selectable("##row", active_view != nil && world_level(active_view.world) == w, {}, {0, h}) do ui_world_focus(w)
    mn, mx := im.GetItemRectMin(), im.GetItemRectMax()
    worlds_row_menu(w.source)

    dl := im.GetWindowDrawList()
    line := im.GetTextLineHeight()
    text := im.GetColorU32ImVec4(im.GetStyleColorVec4(.Text)^)
    y := mn.y + (mx.y - mn.y - line) * 0.5   // centred on the highlight, like the buttons
    x := mn.x + style.FramePadding.x
    im.DrawList_AddText(dl, {x, y}, text, fmt.ctprintf("%s", w.save_path != "" ? ICON_SCENE : ICON_KIT))
    x += line * 1.6
    name := fmt.ctprintf("%s%s", w.title, world_dirty(w) ? "*" : "")
    im.DrawList_AddText(dl, {x, y}, text, name)
    tag_x := x + im.CalcTextSize(name).x + style.ItemSpacing.x
    if w.save_path == "" do tag_x = worlds_tag(dl, {tag_x, y}, tr(.Worlds_Kit_Tag))
    if w.play_world != nil do worlds_tag(dl, {tag_x, y}, tr(.Worlds_Playing_Tag))

    // + / ×, right-aligned on the row: same line as the selectable, so they end the row as real items
    // and layout carries on below them (moving the cursor back afterwards would trip ImGui's
    // "SetCursorPos extended the boundaries" assert after the last row).
    // Auto-sized (glyph + FramePadding), like the toolbar's: a fixed square narrower than that
    // left-aligns the icon at the padding and it overflows right, off centre.
    add_label   := fmt.ctprintf("%s##newview", ICON_ADD)
    close_label := fmt.ctprintf("%s##close", ICON_CLOSE)
    // Both placed explicitly, centred on the row's highlight (a Selectable's rect extends half the item
    // spacing above and below its line, so its top edge sits too high). After SameLine() ImGui would
    // instead line the second button's text baseline up with the selectable, nudging it lower.
    pad := style.FramePadding.x * 2
    add_w   := im.CalcTextSize(add_label, nil, true).x + pad
    close_w := im.CalcTextSize(close_label, nil, true).x + pad
    by := mn.y + (mx.y - mn.y - im.GetFrameHeight()) * 0.5
    im.SameLine()
    im.SetCursorScreenPos({mx.x - close_w - style.ItemSpacing.x - add_w, by})
    if im.Button(add_label) do app_view_open(w.play_world != nil ? w.play_world : w)   // while playing, another view of the game
    im.SetItemTooltip("%s", tr(.Btn_New_Viewport))
    im.SameLine()
    im.SetCursorScreenPos({mx.x - close_w, by})
    if im.Button(close_label) do ui_request_close_world(w)
    im.SetItemTooltip("%s", tr(.Btn_Close))
}

// Brings `w` forward: its view (editor_view_for_world: the active one if it shows `w`, its play world
// included) becomes active and its window takes focus.
ui_world_focus :: proc(w: ^World) {
    ev := editor_view_for_world(w)
    if ev == nil do return
    view_activate(ev.view)
    im.SetWindowFocusStr(fmt.ctprintf("###host%d", ev.view.id))   // its world window ("###view<id>" are extra viewports)
}

// Rescans the .level files for the Scenes list on its next draw (a level was created outside the UI).
ui_scenes_rescan :: proc() {
    ui.scene_paths_scanned = false
}

// The New Scene popup under the Scenes header's +: a name, the path it makes, Create (or Enter). Creates
// an empty level (app_new_scene), opens it and rescans the list. Names are ASCII paths like asset keys:
// letters, digits, _ and -, with / for subfolders.
@(private="file")
worlds_new_scene_popup :: proc() {
    if !im.BeginPopup("##new_scene") do return
    defer im.EndPopup()

    if im.IsWindowAppearing() do im.SetKeyboardFocusHere()
    im.SetNextItemWidth(240 * app.display_scale)
    entered := im.InputTextWithHint("##name", tr(.Worlds_New_Scene_Hint), cstring(&worlds_ui.new_name[0]), len(worlds_ui.new_name), {.EnterReturnsTrue})
    name := string(cstring(&worlds_ui.new_name[0]))
    path := fmt.tprintf("%s%s%s", NEW_SCENE_DIR, name, LEVEL_EXT)

    problem: Maybe(Loc_ID)
    switch {
    case name == "":                    problem = nil
    case !worlds_scene_name_valid(name): problem = .Worlds_New_Scene_Bad_Name
    case os.exists(path):               problem = .Worlds_New_Scene_Exists
    }
    if id, bad := problem.?; bad do im.TextColored(UI_COLOR_ERROR, "%s", tr(id))
    else do im.TextDisabled("%s", fmt.ctprintf("%s", name == "" ? NEW_SCENE_DIR : path))

    ok := name != "" && problem == nil
    im.BeginDisabled(!ok)
    clicked := im.Button(tr(.Btn_Create))
    im.EndDisabled()
    if ok && (clicked || entered) {
        if app_new_scene(path) != nil {
            worlds_ui.new_name = {}
            ui_scenes_rescan()
            im.CloseCurrentPopup()
        }
    }
}

@(private="file")
worlds_scene_name_valid :: proc(name: string) -> bool {
    if name[0] == '/' || name[len(name) - 1] == '/' || strings.contains(name, "//") do return false
    for c in name {
        switch c {
        case 'a'..='z', 'A'..='Z', '0'..='9', '_', '-', '/':
        case: return false
        }
    }
    return true
}

// A collapsible section header: icon, title and a dimmed count. Open by default. `scenes` leaves room
// for the + (New Scene, worlds_ui.new_pressed) and refresh (worlds_refresh_clicked) buttons drawn over
// its right end.
@(private="file")
worlds_section :: proc(icon: string, title: cstring, count: int, id: string, scenes := false) -> bool {
    im.Spacing()
    if scenes do im.SetNextItemAllowOverlap()
    // Neutral grey bars (VS Code's section headers), not the selection blue Header* would give.
    im.PushStyleColorImVec4(.Header,        {0.17, 0.17, 0.17, 1})
    im.PushStyleColorImVec4(.HeaderHovered, {0.22, 0.22, 0.22, 1})
    im.PushStyleColorImVec4(.HeaderActive,  {0.25, 0.25, 0.25, 1})
    open := im.CollapsingHeader(fmt.ctprintf("%s  %s  (%d)###section_%s", icon, title, count, id), {.DefaultOpen})
    im.PopStyleColor(3)
    if scenes {
        style := im.GetStyle()
        new_label := fmt.ctprintf("%s##new_scene", ICON_ADD)
        refresh_label := fmt.ctprintf("%s##refresh", ICON_REFRESH)
        w := im.CalcTextSize(new_label, nil, true).x + im.CalcTextSize(refresh_label, nil, true).x + style.FramePadding.x * 4 + style.ItemSpacing.x
        im.SameLine()
        im.SetCursorPosX(im.GetCursorPosX() + im.GetContentRegionAvail().x - w)   // flush right
        worlds_ui.new_pressed = im.SmallButton(new_label)
        im.SetItemTooltip("%s", tr(.Btn_New_Scene))
        im.SameLine()
        worlds_ui_refresh_pressed = im.SmallButton(refresh_label)
        im.SetItemTooltip("%s", tr(.Btn_Refresh))
    }
    return open
}

@(private="file") worlds_ui_refresh_pressed: bool

@(private="file")
worlds_refresh_clicked :: proc() -> bool {
    pressed := worlds_ui_refresh_pressed
    worlds_ui_refresh_pressed = false
    return pressed
}

// A two-line selectable row: icon, name, and a dimmed detail line, with an optional tag (e.g. "open")
// right after the name. Returns whether it was clicked.
@(private="file")
worlds_row :: proc(icon, name, detail: string, tag: cstring) -> (clicked: bool) {
    style := im.GetStyle()
    line := im.GetTextLineHeight()
    h := line * 2 + style.FramePadding.y * 2
    clicked = im.Selectable("##row", false, {}, {0, h})
    mn := im.GetItemRectMin()

    dl := im.GetWindowDrawList()
    text := im.GetColorU32ImVec4(im.GetStyleColorVec4(.Text)^)
    dim  := im.GetColorU32ImVec4(im.GetStyleColorVec4(.TextDisabled)^)
    pad  := style.FramePadding.x
    im.DrawList_AddText(dl, {mn.x + pad, mn.y + (h - line) * 0.5}, text, fmt.ctprintf("%s", icon))
    x := mn.x + pad + line * 1.6
    name_c := fmt.ctprintf("%s", name)
    im.DrawList_AddText(dl, {x, mn.y + style.FramePadding.y}, text, name_c)
    im.DrawList_AddText(dl, {x, mn.y + style.FramePadding.y + line}, dim, fmt.ctprintf("%s", detail))
    if tag != nil do worlds_tag(dl, {x + im.CalcTextSize(name_c).x + style.ItemSpacing.x, mn.y + style.FramePadding.y}, tag)
    return
}

// The right-click menu of the row just drawn (a scene or kit): show its file in Explorer, to edit and
// resave it outside the engine.
@(private="file")
worlds_row_menu :: proc(path: string) {
    if im.BeginPopupContextItem("##row_menu") {
        if im.MenuItem(fmt.ctprintf("%s  %s", ICON_FOLDER_OPEN, tr(.Btn_Show_In_Explorer))) do app_show_in_explorer(path)
        im.EndPopup()
    }
}

// A small accent-tinted pill with a word in it ("open", "kit").
// Returns where a following tag would go.
@(private="file")
worlds_tag :: proc(dl: ^im.DrawList, pos: [2]f32, tag: cstring) -> (next_x: f32) {
    sz := im.CalcTextSize(tag)
    accent := im.GetStyleColorVec4(.ButtonActive)^
    im.DrawList_AddRectFilled(dl, {pos.x - 4, pos.y}, {pos.x + sz.x + 4, pos.y + sz.y}, im.GetColorU32ImVec4({accent.x, accent.y, accent.z, 0.35}), 3)
    im.DrawList_AddText(dl, pos, im.GetColorU32ImVec4(im.GetStyleColorVec4(.Text)^), tag)
    return pos.x + sz.x + 8 + im.GetStyle().ItemSpacing.x
}

// Open worlds the Worlds window lists: levels, not their play copies.
@(private="file")
worlds_level_count :: proc() -> (n: int) {
    for w in worlds do if w.play_source == nil do n += 1
    return
}

// Dimmed text that wraps at the window edge (TextDisabled doesn't wrap).
text_dim_wrapped :: proc(s: cstring) {
    im.PushStyleColorImVec4(.Text, im.GetStyleColorVec4(.TextDisabled)^)
    im.TextWrapped("%s", s)
    im.PopStyleColor()
}
