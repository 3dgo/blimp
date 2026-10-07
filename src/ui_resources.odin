package blimp

import "core:fmt"
import "core:slice"
import "core:strings"
import im "lib:odin-imgui"
import "vendor:directx/d3d12"
import "dx"

// Resources window: what the GPU holds and who owns it, one block per resource in a treemap whose area
// is its byte size (like Unreal's Size Map), grouped by owner — the shared assets (Asset_Buffers), each
// open world (its draw mirror, baked probes and probe atlas), each view (its render targets) and the
// engine — and coloured by kind, with a per-kind bar above it. Bytes are the GPU-side resource; the
// upload-heap staging copy most of them keep is not counted. Rebuilt each frame in scratch.
//
// Clicking a group shows only it, filling the window (Back or Backspace returns to all). Hovering a
// texture shows the picture; right-clicking a block offers Show in Explorer on the file it came from.

Resource_Kind :: enum { Texture, Geometry, Table, Probes, Frame_Data, Target }

Resource_Item :: struct {
    owner:  string,   // the treemap group: Assets, a world's title, a view, Engine
    name:   string,   // asset key, or the resource's label
    kind:   Resource_Kind,
    bytes:  int,
    detail: string,   // tooltip line: dimensions, counts, capacity
    atlas:  ^World,   // a probe atlas: its world, so the tooltip can show the picture
    image:  int,      // an asset texture: its asset_system.images index, for the tooltip picture; -1 otherwise
    file:   string,   // the file it came from (glTF, image, .level), for Show in Explorer; "" if none
}

@(private="file")
resources_ui: struct {
    focus:      sbuf128,   // the one owner shown, filling the treemap; "" shows them all
    menu_owner: sbuf128,   // the right-clicked block's owner and file, for its menu
    menu_file:  sbuf256,
}

@(rodata, private="file")
KIND_LABEL := [Resource_Kind]Loc_ID{
    .Texture    = .Res_Kind_Texture,
    .Geometry   = .Res_Kind_Geometry,
    .Table      = .Res_Kind_Table,
    .Probes     = .Res_Kind_Probes,
    .Frame_Data = .Res_Kind_Frame_Data,
    .Target     = .Res_Kind_Target,
}

@(rodata, private="file")
KIND_COLOR := [Resource_Kind][3]f32{
    .Texture    = {0.24, 0.47, 0.78},
    .Geometry   = {0.30, 0.60, 0.36},
    .Table      = {0.76, 0.53, 0.22},
    .Probes     = {0.80, 0.36, 0.30},
    .Frame_Data = {0.55, 0.40, 0.72},
    .Target     = {0.36, 0.58, 0.62},
}

RESOURCES_WINDOW_SIZE :: [2]f32{760, 500}   // first-open size (× display scale)
RESOURCE_PREVIEW :: 256                     // a texture's or probe atlas's tooltip picture, longest side in points

// Every GPU resource, largest first. Texture bytes are the RGBA8 pixels (one mip); geometry is a mesh's
// index, position and attribute ranges; per-frame buffers count every frame in flight at full capacity.
resource_items :: proc(allocator := context.temp_allocator) -> []Resource_Item {
    items := make([dynamic]Resource_Item, 0, len(asset_system.images) + len(asset_system.meshes) + 16 * (len(worlds) + len(views) + 1), allocator)
    add :: proc(items: ^[dynamic]Resource_Item, owner, name: string, kind: Resource_Kind, bytes: int, detail: string, atlas: ^World = nil, image := -1, file := "") {
        append(items, Resource_Item{owner, name, kind, bytes, detail, atlas, image, file})
    }
    // A fixed-capacity buffer: count × element size, times the frames in flight when it's per frame.
    capacity :: proc(count, size, flights: int, allocator := context.temp_allocator) -> string {
        if flights > 1 do return fmt.aprintf("%d × %d B × %d %s", count, size, flights, trs(.Res_Flights), allocator = allocator)
        return fmt.aprintf("%d × %d B", count, size, allocator = allocator)
    }

    // Shared assets. An image can sit under several keys once kits share it; name it by the first key
    // alphabetically (map order isn't stable frame to frame) and count the rest.
    assets := trs(.Res_Owner_Assets)
    image_name := make([]string, len(asset_system.images), context.temp_allocator)
    image_keys := make([]int, len(asset_system.images), context.temp_allocator)
    for key, idx in asset_system.image_ids {
        if image_name[idx] == "" || key < image_name[idx] do image_name[idx] = key
        image_keys[idx] += 1
    }
    for img, i in asset_system.images {
        detail := fmt.aprintf("%d × %d RGBA8", img.width, img.height, allocator = allocator)
        if image_keys[i] > 1 do detail = fmt.aprintf("%s · %s", detail, fmt.tprintf(trs(.Asset_Shared), image_keys[i]), allocator = allocator)
        add(&items, assets, image_name[i], .Texture, len(img.pixels), detail, image = i, file = asset_key_file(image_name[i]))
    }
    mesh_name := make([]string, len(asset_system.meshes), context.temp_allocator)
    for key, idx in asset_system.mesh_ids do mesh_name[idx] = key
    for m, i in asset_system.meshes {
        bytes := int(m.index_count) * size_of(u32) + int(m.vertex_count) * (size_of(vec3) + size_of(Vertex_Attributes))
        add(&items, assets, mesh_name[i], .Geometry, bytes, fmt.aprintf(trs(.Asset_Mesh_Detail), m.vertex_count, m.index_count / 3, allocator = allocator), file = asset_key_file(mesh_name[i]))
    }
    add(&items, assets, trs(.Asset_Mesh_Table), .Table, len(asset_system.meshes) * size_of(Mesh), capacity(len(asset_system.meshes), size_of(Mesh), 1, allocator))
    add(&items, assets, trs(.Asset_Material_Table), .Table, len(asset_system.materials) * size_of(Material), capacity(len(asset_system.materials), size_of(Material), 1, allocator))

    // Each world: its per-frame draw mirror (fixed capacity, render_buffers.odin) and its baked probes.
    F :: FRAMES_IN_FLIGHT
    for w in worlds {
        first := len(items)
        defer for &it in items[first:] do it.file = w.source   // its .level or glTF
        add(&items, w.title, trs(.Res_Transforms),     .Frame_Data, MAX_MESH_INSTANCES * size_of(mat4) * F, capacity(MAX_MESH_INSTANCES, size_of(mat4), F, allocator))
        add(&items, w.title, trs(.Res_Mesh_Instances), .Frame_Data, MAX_MESH_INSTANCES * size_of(Mesh_Instance_Data) * F, capacity(MAX_MESH_INSTANCES, size_of(Mesh_Instance_Data), F, allocator))
        add(&items, w.title, trs(.Res_Lights),         .Frame_Data, MAX_LIGHTS * size_of(GPU_Light) * F, capacity(MAX_LIGHTS, size_of(GPU_Light), F, allocator))
        add(&items, w.title, trs(.Res_Draw_Commands),  .Frame_Data, MAX_MESH_INSTANCES * size_of(d3d12.DRAW_INDEXED_ARGUMENTS) * F, capacity(MAX_MESH_INSTANCES, size_of(d3d12.DRAW_INDEXED_ARGUMENTS), F, allocator))
        add(&items, w.title, trs(.Res_Shadow_Maps),    .Target, MAX_SHADOW_SLICES * SHADOW_MAP_SIZE * SHADOW_MAP_SIZE * 4,
            fmt.aprintf("%d × %d R32 × %d · %d in use", SHADOW_MAP_SIZE, SHADOW_MAP_SIZE, MAX_SHADOW_SLICES, len(w.render.shadow_slices), allocator = allocator))
        add(&items, w.title, trs(.Res_Shadow_Views),   .Frame_Data, MAX_SHADOW_SLICES * size_of(Shadow_View) * F, capacity(MAX_SHADOW_SLICES, size_of(Shadow_View), F, allocator))
        g := &w.probes
        if w.render.probes.resource.handle != nil {
            add(&items, w.title, trs(.Res_Probes), .Probes, len(g.probes) * size_of(Probe_SH),
                fmt.aprintf("%d × %d × %d × %d layers · %s", g.dims.x, g.dims.y, g.dims.z, g.layers, capacity(len(g.probes), size_of(Probe_SH), 1), allocator = allocator))
            add(&items, w.title, trs(.Res_Probe_Depth), .Probes, len(g.depth) * size_of(Probe_Depth),
                fmt.aprintf("%d × %d octahedral · %s", PROBE_DEPTH_RES, PROBE_DEPTH_RES, capacity(len(g.depth), size_of(Probe_Depth), 1), allocator = allocator))
        }
        if w.render.probe_atlas.resource.handle != nil {
            add(&items, w.title, trs(.Bake_Atlas), .Texture, len(g.atlas.pixels), fmt.aprintf("%d × %d RGBA8", g.atlas.width, g.atlas.height, allocator = allocator), w)
        }
    }

    // Each view: its targets (display RGBA8; scene HDR RGBA16F and depth R32 at the scene size) and constants.
    for v in views {
        owner := fmt.aprintf("%s %d · %s", trs(.Res_Owner_View), v.id, v.world.title, allocator = allocator)
        t := &v.target
        add(&items, owner, trs(.Res_Display_Target), .Target, int(t.width * t.height) * 4, fmt.aprintf("%d × %d RGBA8", t.width, t.height, allocator = allocator))
        add(&items, owner, trs(.Res_Scene_Target),   .Target, int(t.scene_width * t.scene_height) * 8, fmt.aprintf("%d × %d RGBA16F", t.scene_width, t.scene_height, allocator = allocator))
        add(&items, owner, trs(.Res_Depth_Target),   .Target, int(t.scene_width * t.scene_height) * 4, fmt.aprintf("%d × %d R32", t.scene_width, t.scene_height, allocator = allocator))
        add(&items, owner, trs(.Res_Frame_Constants), .Frame_Data, size_of(Frame_Constants) * F, capacity(1, size_of(Frame_Constants), F, allocator))
    }

    // The engine's own: the swapchain and the shared debug-line buffer.
    engine := trs(.Res_Owner_Engine)
    sc := &renderer_dx.swapchain
    add(&items, engine, trs(.Res_Swapchain), .Target, int(app.window_width * app.window_height) * 4 * len(sc.back_buffers),
        fmt.aprintf("%d × %d RGBA8 × %d", app.window_width, app.window_height, len(sc.back_buffers), allocator = allocator))
    add(&items, engine, trs(.Res_Debug_Lines), .Frame_Data, MAX_DEBUG_LINE_VERTS * size_of(Debug_Line_Vertex) * F, capacity(MAX_DEBUG_LINE_VERTS, size_of(Debug_Line_Vertex), F, allocator))

    slice.sort_by(items[:], proc(a, b: Resource_Item) -> bool { return a.bytes > b.bytes })
    return items[:]
}

bytes_text :: proc(n: int) -> string {
    switch {
    case n >= 1 << 20: return fmt.tprintf("%.2f MB", f64(n) / (1 << 20))
    case n >= 1 << 10: return fmt.tprintf("%.1f KB", f64(n) / (1 << 10))
    }
    return fmt.tprintf("%d B", n)
}

ui_draw_resources :: proc() {
    s := app.display_scale
    im.SetNextWindowSize({RESOURCES_WINDOW_SIZE.x * s, RESOURCES_WINDOW_SIZE.y * s}, .FirstUseEver)
    if im.Begin(tr(.Win_Resources), &ui.show_resources) {
        items := resource_items()
        if focus := sbuf_str(&resources_ui.focus); focus != "" {
            kept := make([dynamic]Resource_Item, 0, len(items), context.temp_allocator)
            for it in items do if it.owner == focus do append(&kept, it)
            if len(kept) > 0 do items = kept[:]
            else do sbuf_set(&resources_ui.focus, "")   // its world or view was closed
        }
        focused := sbuf_str(&resources_ui.focus) != ""
        totals: [Resource_Kind]int
        total := 0
        for it in items {
            totals[it.kind] += it.bytes
            total += it.bytes
        }

        summary := fmt.tprintf("%s · %s", bytes_text(total), fmt.tprintf(trs(.Res_Count), len(items)))
        if focused {
            back := im.Button(fmt.ctprintf("%s##back", ICON_BACK))
            im.SetItemTooltip("%s", tr(.Res_Back))
            back ||= im.IsWindowFocused(im.FocusedFlags_RootAndChildWindows) && im.IsKeyPressed(.Backspace)
            im.SameLine()
            im.AlignTextToFramePadding()
            im.Text("%s", fmt.ctprintf("%s › %s · %s", trs(.Res_All), sbuf_str(&resources_ui.focus), summary))
            if back do sbuf_set(&resources_ui.focus, "")
        } else {
            im.Text("%s", fmt.ctprintf("%s", summary))
        }
        resource_kind_bar(totals, total)
        resource_treemap(items, focused)
        resource_menu(focused)
    }
    im.End()
}

// One bar split by kind, with a legend line under it (kinds with nothing are left out).
@(private="file")
resource_kind_bar :: proc(totals: [Resource_Kind]int, total: int) {
    dl := im.GetWindowDrawList()
    p := im.GetCursorScreenPos()
    w := im.GetContentRegionAvail().x
    h := im.GetTextLineHeight() * 0.6
    x := p.x
    for kind in Resource_Kind {
        if total == 0 do break
        seg := w * f32(totals[kind]) / f32(total)
        im.DrawList_AddRectFilled(dl, {x, p.y}, {x + seg, p.y + h}, kind_color(kind, 1))
        x += seg
    }
    im.Dummy({w, h})

    line := im.GetTextLineHeight()
    first := true
    for kind in Resource_Kind {
        if totals[kind] == 0 do continue
        if !first do im.SameLine(0, line)
        first = false
        q := im.GetCursorScreenPos()
        im.DrawList_AddRectFilled(dl, {q.x, q.y + line * 0.2}, {q.x + line * 0.6, q.y + line * 0.8}, kind_color(kind, 1), 2)
        im.Dummy({line * 0.6, line})
        im.SameLine()
        pct := total > 0 ? 100 * f64(totals[kind]) / f64(total) : 0
        im.Text("%s", fmt.ctprintf("%s %s (%.0f%%)", trs(KIND_LABEL[kind]), bytes_text(totals[kind]), pct))
    }
}

// The treemap fills the rest of the window: owners first, then each owner's resources inside its block,
// coloured by kind.
@(private="file")
resource_treemap :: proc(items: []Resource_Item, focused: bool) {
    avail := im.GetContentRegionAvail()
    if avail.x < 8 || avail.y < 8 do return
    origin := im.GetCursorScreenPos()
    clicked := im.InvisibleButton("##treemap", avail)   // owns the area so hovering is the canvas's, and drags don't fall through
    hovered_canvas := im.IsItemHovered()
    right_clicked := hovered_canvas && im.IsMouseClicked(.Right)
    mouse := im.GetMousePos()
    dl := im.GetWindowDrawList()
    line := im.GetTextLineHeight()
    text_col := im.GetColorU32ImVec4({1, 1, 1, 0.92})
    edge_col := im.GetColorU32ImVec4(im.GetStyle().Colors[im.Col.WindowBg])
    group_col := im.GetColorU32ImVec4({0.22, 0.22, 0.24, 1})

    // Owners largest first, as the layout wants.
    Group :: struct { owner: string, size: f32 }
    groups := make([dynamic]Group, 0, 16, context.temp_allocator)
    outer: for it in items {
        for &grp in groups do if grp.owner == it.owner { grp.size += f32(it.bytes); continue outer }
        append(&groups, Group{it.owner, f32(it.bytes)})
    }
    slice.sort_by(groups[:], proc(a, b: Group) -> bool { return a.size > b.size })
    group_sizes := make([]f32, len(groups), context.temp_allocator)
    for grp, i in groups do group_sizes[i] = grp.size
    group_rects := treemap_layout(group_sizes, {origin, origin + avail})

    hovered, hovered_group := -1, -1
    for grp, g in groups {
        r := group_rects[g]
        im.DrawList_AddRectFilled(dl, r.min, r.max, group_col)
        if hovered_canvas && mouse.x >= r.min.x && mouse.x < r.max.x && mouse.y >= r.min.y && mouse.y < r.max.y do hovered_group = g

        // A header strip names the owner when the block has room for it.
        inner := Treemap_Rect{r.min + 1, r.max - 1}
        if r.max.y - r.min.y > line * 3 {
            label := fmt.ctprintf("%s · %s", grp.owner, bytes_text(int(grp.size)))
            resource_label(dl, r.min + {4, 1}, {r.max.x - 4, r.min.y + line + 2}, label, text_col)
            inner.min.y += line + 2
        }

        members := make([dynamic]int, 0, len(items), context.temp_allocator)   // stays largest first, like items
        for it, i in items do if it.owner == grp.owner do append(&members, i)
        sizes := make([]f32, len(members), context.temp_allocator)
        for m, i in members do sizes[i] = f32(items[m].bytes)
        rects := treemap_layout(sizes, inner)

        for m, i in members {
            b := rects[i]
            if b.max.x - b.min.x < 1 || b.max.y - b.min.y < 1 do continue
            kind := items[m].kind
            shade := 0.85 + 0.15 * f32((m * 7) % 4) / 3   // neighbours differ slightly
            im.DrawList_AddRectFilled(dl, b.min, b.max, kind_color(kind, shade))
            im.DrawList_AddRect(dl, b.min, b.max, edge_col)
            if hovered_canvas && mouse.x >= b.min.x && mouse.x < b.max.x && mouse.y >= b.min.y && mouse.y < b.max.y {
                hovered = m
                im.DrawList_AddRect(dl, b.min, b.max, im.GetColorU32ImVec4({1, 1, 1, 1}), 0, 2)
            }
            if b.max.x - b.min.x > line * 2.5 && b.max.y - b.min.y > line + 4 {
                it := items[m]
                resource_label(dl, b.min + 4, b.max - 2, fmt.ctprintf("%s", short_name(it.name)), text_col)
                if b.max.y - b.min.y > line * 2 + 6 {
                    resource_label(dl, b.min + {4, 4 + line}, b.max - 2, fmt.ctprintf("%s", bytes_text(it.bytes)), text_col)
                }
            }
        }
    }

    // Click a group (its header or any block in it) to show only it; right-click a block for its menu.
    if clicked && !focused && hovered_group >= 0 do sbuf_set(&resources_ui.focus, groups[hovered_group].owner)
    if right_clicked && hovered >= 0 {
        sbuf_set(&resources_ui.menu_owner, items[hovered].owner)
        sbuf_set(&resources_ui.menu_file, items[hovered].file)
        im.OpenPopup("##resource_menu")
    }

    if hovered >= 0 {
        it := items[hovered]
        im.BeginTooltip()
        im.Text("%s", fmt.ctprintf("%s", it.name))
        im.TextDisabled("%s", fmt.ctprintf("%s · %s · %s", it.owner, trs(KIND_LABEL[it.kind]), bytes_text(it.bytes)))
        im.TextDisabled("%s", fmt.ctprintf("%s", it.detail))
        if it.atlas != nil do ui_probe_atlas_image(it.atlas, RESOURCE_PREVIEW * app.display_scale)
        if it.image >= 0 do resource_texture_image(it.image, RESOURCE_PREVIEW * app.display_scale)
        if !focused do im.TextDisabled("%s", tr(.Res_Hint_Focus))
        if it.file != "" do im.TextDisabled("%s", tr(.Res_Hint_Explorer))
        im.EndTooltip()
    }
}

// The right-clicked block's menu: show only its group, show its file in Explorer.
@(private="file")
resource_menu :: proc(focused: bool) {
    if !im.BeginPopup("##resource_menu") do return
    defer im.EndPopup()
    owner := sbuf_str(&resources_ui.menu_owner)
    if !focused && im.MenuItem(fmt.ctprintf(trs(.Res_Focus), owner)) do sbuf_set(&resources_ui.focus, owner)
    file := sbuf_str(&resources_ui.menu_file)
    if im.MenuItem(fmt.ctprintf("%s  %s", ICON_FOLDER_OPEN, tr(.Btn_Show_In_Explorer)), nil, false, file != "") do app_show_in_explorer(file)
}

// An asset texture, its longest side `size` points (the ImGui-heap SRV asset_buffers_create made for it).
@(private="file")
resource_texture_image :: proc(image: int, size: f32) {
    if image >= len(asset_buffers.texture_ui) do return   // mid hot reload
    img := asset_system.images[image]
    scale := size / f32(max(img.width, img.height, 1))
    gpu := dx.descriptor_heap_gpu_handle_at(renderer_dx.ui_heap, asset_buffers.texture_ui[image].heap_slot)
    im.Image(im.TextureRef{_TexID = im.TextureID(gpu.ptr)}, {f32(img.width) * scale, f32(img.height) * scale})
}

// The file an asset key comes from, the path before its first ':' ("assets/models/car.gltf:body" ->
// "assets/models/car.gltf"); "" for a key that isn't a path (a built-in image like "white").
@(private="file")
asset_key_file :: proc(key: string) -> string {
    file := key
    if i := strings.index_byte(key, ':'); i >= 0 do file = key[:i]
    return strings.contains_rune(file, '/') ? file : ""
}

// Text clipped to a block, so a long key never spills into its neighbour.
@(private="file")
resource_label :: proc(dl: ^im.DrawList, p, clip_max: [2]f32, text: cstring, col: u32) {
    im.DrawList_PushClipRect(dl, p, clip_max, true)
    im.DrawList_AddText(dl, p, col, text)
    im.DrawList_PopClipRect(dl)
}

// The key without its directory: "assets/models/castle.gltf:wall001:0" → "castle.gltf:wall001:0".
@(private="file")
short_name :: proc(key: string) -> string {
    if i := strings.last_index_byte(key, '/'); i >= 0 do return key[i + 1:]
    return key
}

@(private="file")
kind_color :: proc(kind: Resource_Kind, shade: f32) -> u32 {
    c := KIND_COLOR[kind] * shade
    return im.GetColorU32ImVec4({c.r, c.g, c.b, 1})
}

Treemap_Rect :: struct { min, max: [2]f32 }

// Squarified treemap (Bruls, Huizing, van Wijk): blocks whose areas are proportional to `sizes`
// (largest first), kept close to square. Each step fills one strip along the rectangle's shorter side,
// adding blocks while that improves the strip's worst aspect ratio, then lays out the rest in what's
// left. Returns scratch rects indexed like `sizes`.
treemap_layout :: proc(sizes: []f32, r: Treemap_Rect) -> []Treemap_Rect {
    out := make([]Treemap_Rect, len(sizes), context.temp_allocator)
    total: f32 = 0
    for size in sizes do total += size
    if total <= 0 do return out

    rect := r
    scale := (r.max.x - r.min.x) * (r.max.y - r.min.y) / total   // bytes → area
    worst :: proc(largest, smallest, sum, side: f32) -> f32 {
        return max(side * side * largest / (sum * sum), sum * sum / (side * side * smallest))
    }

    i := 0
    for i < len(sizes) {
        wide := rect.max.x - rect.min.x >= rect.max.y - rect.min.y
        side := wide ? rect.max.y - rect.min.y : rect.max.x - rect.min.x

        largest := sizes[i] * scale
        sum := largest
        ratio := worst(largest, largest, sum, side)
        j := i + 1
        for j < len(sizes) {
            a := sizes[j] * scale
            next := worst(largest, a, sum + a, side)
            if next > ratio do break
            ratio, sum = next, sum + a
            j += 1
        }

        // The strip: a column at the left of a wide rectangle, a row along the top of a tall one.
        thick := side > 0 ? sum / side : 0
        p := rect.min
        for k in i ..< j {
            run := thick > 0 ? sizes[k] * scale / thick : 0
            if wide {
                out[k] = {p, {p.x + thick, p.y + run}}
                p.y += run
            } else {
                out[k] = {p, {p.x + run, p.y + thick}}
                p.x += run
            }
        }
        if wide do rect.min.x += thick
        else    do rect.min.y += thick
        i = j
    }
    return out
}
