package blimp

import "core:fmt"
import "core:slice"
import "core:strings"
import im "lib:odin-imgui"

// Asset Buffers window: what the shared asset GPU buffers (Asset_Buffers) hold, one block per asset in
// a treemap whose area is its byte size (like Unreal's Size Map), grouped and coloured by type, with a
// per-type bar above it. Assets never change after init, so the list is rebuilt from asset_system each
// frame in scratch rather than cached.

Asset_Mem_Kind :: enum { Texture, Geometry, Table }

Asset_Mem_Item :: struct {
    name:   string,   // asset key, or a table's label
    kind:   Asset_Mem_Kind,
    bytes:  int,
    detail: string,   // tooltip line: dimensions, vertex/triangle counts, sharing
}

@(rodata, private="file")
KIND_LABEL := [Asset_Mem_Kind]Loc_ID{ .Texture = .Asset_Kind_Texture, .Geometry = .Asset_Kind_Geometry, .Table = .Asset_Kind_Table }

@(rodata, private="file")
KIND_COLOR := [Asset_Mem_Kind][3]f32{
    .Texture  = {0.24, 0.47, 0.78},
    .Geometry = {0.30, 0.60, 0.36},
    .Table    = {0.76, 0.53, 0.22},
}

ASSET_BUFFERS_WINDOW_SIZE :: [2]f32{760, 500}   // first-open size (× display scale)

// Every asset's GPU payload, largest first. Texture bytes are the RGBA8 pixels (one mip); geometry is
// a mesh's index, position and attribute ranges.
asset_mem_items :: proc(allocator := context.temp_allocator) -> []Asset_Mem_Item {
    items := make([dynamic]Asset_Mem_Item, 0, len(asset_system.images) + len(asset_system.meshes) + 2, allocator)

    // An image can sit under several keys once kits share it; name it by the first key alphabetically
    // (map order isn't stable frame to frame) and count the rest.
    image_name := make([]string, len(asset_system.images), context.temp_allocator)
    image_keys := make([]int, len(asset_system.images), context.temp_allocator)
    for key, idx in asset_system.image_ids {
        if image_name[idx] == "" || key < image_name[idx] do image_name[idx] = key
        image_keys[idx] += 1
    }
    for img, i in asset_system.images {
        detail := fmt.aprintf("%d × %d RGBA8", img.width, img.height, allocator = allocator)
        if image_keys[i] > 1 do detail = fmt.aprintf("%s · %s", detail, fmt.tprintf(trs(.Asset_Shared), image_keys[i]), allocator = allocator)
        append(&items, Asset_Mem_Item{image_name[i], .Texture, len(img.pixels), detail})
    }

    mesh_name := make([]string, len(asset_system.meshes), context.temp_allocator)
    for key, idx in asset_system.mesh_ids do mesh_name[idx] = key
    for m, i in asset_system.meshes {
        bytes := int(m.index_count) * size_of(u32) + int(m.vertex_count) * (size_of(vec3) + size_of(Vertex_Attributes))
        detail := fmt.aprintf(trs(.Asset_Mesh_Detail), m.vertex_count, m.index_count / 3, allocator = allocator)
        append(&items, Asset_Mem_Item{mesh_name[i], .Geometry, bytes, detail})
    }

    append(&items, Asset_Mem_Item{trs(.Asset_Mesh_Table), .Table, len(asset_system.meshes) * size_of(Mesh),
        fmt.aprintf("%d × %d B", len(asset_system.meshes), size_of(Mesh), allocator = allocator)})
    append(&items, Asset_Mem_Item{trs(.Asset_Material_Table), .Table, len(asset_system.materials) * size_of(Material),
        fmt.aprintf("%d × %d B", len(asset_system.materials), size_of(Material), allocator = allocator)})

    slice.sort_by(items[:], proc(a, b: Asset_Mem_Item) -> bool { return a.bytes > b.bytes })
    return items[:]
}

bytes_text :: proc(n: int) -> string {
    switch {
    case n >= 1 << 20: return fmt.tprintf("%.2f MB", f64(n) / (1 << 20))
    case n >= 1 << 10: return fmt.tprintf("%.1f KB", f64(n) / (1 << 10))
    }
    return fmt.tprintf("%d B", n)
}

ui_draw_asset_buffers :: proc() {
    s := app.dispaly_scale
    im.SetNextWindowSize({ASSET_BUFFERS_WINDOW_SIZE.x * s, ASSET_BUFFERS_WINDOW_SIZE.y * s}, .FirstUseEver)
    if im.Begin(tr(.Win_Asset_Buffers), &ui.show_asset_buffers) {
        items := asset_mem_items()
        totals: [Asset_Mem_Kind]int
        total := 0
        for it in items {
            totals[it.kind] += it.bytes
            total += it.bytes
        }

        im.Text("%s", fmt.ctprintf("%s · %s", bytes_text(total), fmt.tprintf(trs(.Asset_Count), len(items))))
        asset_type_bar(totals, total)
        asset_treemap(items, totals)
    }
    im.End()
}

// One bar split by type, with a legend line under it.
@(private="file")
asset_type_bar :: proc(totals: [Asset_Mem_Kind]int, total: int) {
    dl := im.GetWindowDrawList()
    p := im.GetCursorScreenPos()
    w := im.GetContentRegionAvail().x
    h := im.GetTextLineHeight() * 0.6
    x := p.x
    for kind in Asset_Mem_Kind {
        if total == 0 do break
        seg := w * f32(totals[kind]) / f32(total)
        im.DrawList_AddRectFilled(dl, {x, p.y}, {x + seg, p.y + h}, kind_color(kind, 1))
        x += seg
    }
    im.Dummy({w, h})

    line := im.GetTextLineHeight()
    for kind, i in Asset_Mem_Kind {
        if i > 0 do im.SameLine(0, line)
        q := im.GetCursorScreenPos()
        im.DrawList_AddRectFilled(dl, {q.x, q.y + line * 0.2}, {q.x + line * 0.6, q.y + line * 0.8}, kind_color(kind, 1), 2)
        im.Dummy({line * 0.6, line})
        im.SameLine()
        pct := total > 0 ? 100 * f64(totals[kind]) / f64(total) : 0
        im.Text("%s", fmt.ctprintf("%s %s (%.0f%%)", trs(KIND_LABEL[kind]), bytes_text(totals[kind]), pct))
    }
}

// The treemap fills the rest of the window: types first, then each type's assets inside its block.
@(private="file")
asset_treemap :: proc(items: []Asset_Mem_Item, totals: [Asset_Mem_Kind]int) {
    avail := im.GetContentRegionAvail()
    if avail.x < 8 || avail.y < 8 do return
    origin := im.GetCursorScreenPos()
    im.InvisibleButton("##treemap", avail)   // owns the area so hovering is the canvas's, and drags don't fall through
    hovered_canvas := im.IsItemHovered()
    mouse := im.GetMousePos()
    dl := im.GetWindowDrawList()
    line := im.GetTextLineHeight()
    text_col := im.GetColorU32ImVec4({1, 1, 1, 0.92})
    edge_col := im.GetColorU32ImVec4(im.GetStyle().Colors[im.Col.WindowBg])

    // Types largest first, as the layout wants.
    Group :: struct { kind: Asset_Mem_Kind, size: f32 }
    groups := make([dynamic]Group, 0, len(Asset_Mem_Kind), context.temp_allocator)
    for kind in Asset_Mem_Kind do if totals[kind] > 0 do append(&groups, Group{kind, f32(totals[kind])})
    slice.sort_by(groups[:], proc(a, b: Group) -> bool { return a.size > b.size })
    group_sizes := make([]f32, len(groups), context.temp_allocator)
    for grp, i in groups do group_sizes[i] = grp.size
    group_rects := treemap_layout(group_sizes, {origin, origin + avail})

    hovered := -1
    for grp, g in groups {
        kind := grp.kind
        r := group_rects[g]
        im.DrawList_AddRectFilled(dl, r.min, r.max, kind_color(kind, 0.45))

        // A header strip names the type when the block has room for it.
        inner := Treemap_Rect{r.min + 1, r.max - 1}
        if r.max.y - r.min.y > line * 3 {
            label := fmt.ctprintf("%s · %s", trs(KIND_LABEL[kind]), bytes_text(totals[kind]))
            asset_label(dl, r.min + {4, 1}, {r.max.x - 4, r.min.y + line + 2}, label, text_col)
            inner.min.y += line + 2
        }

        members := make([dynamic]int, 0, len(items), context.temp_allocator)   // stays largest first, like items
        for it, i in items do if it.kind == kind do append(&members, i)
        sizes := make([]f32, len(members), context.temp_allocator)
        for m, i in members do sizes[i] = f32(items[m].bytes)
        rects := treemap_layout(sizes, inner)

        for m, i in members {
            b := rects[i]
            if b.max.x - b.min.x < 1 || b.max.y - b.min.y < 1 do continue
            shade := 0.85 + 0.15 * f32((m * 7) % 4) / 3   // neighbours differ slightly
            im.DrawList_AddRectFilled(dl, b.min, b.max, kind_color(kind, shade))
            im.DrawList_AddRect(dl, b.min, b.max, edge_col)
            if hovered_canvas && mouse.x >= b.min.x && mouse.x < b.max.x && mouse.y >= b.min.y && mouse.y < b.max.y {
                hovered = m
                im.DrawList_AddRect(dl, b.min, b.max, im.GetColorU32ImVec4({1, 1, 1, 1}), 0, 2)
            }
            if b.max.x - b.min.x > line * 2.5 && b.max.y - b.min.y > line + 4 {
                it := items[m]
                asset_label(dl, b.min + 4, b.max - 2, fmt.ctprintf("%s", short_name(it.name)), text_col)
                if b.max.y - b.min.y > line * 2 + 6 {
                    asset_label(dl, b.min + {4, 4 + line}, b.max - 2, fmt.ctprintf("%s", bytes_text(it.bytes)), text_col)
                }
            }
        }
    }

    if hovered >= 0 {
        it := items[hovered]
        im.BeginTooltip()
        im.Text("%s", fmt.ctprintf("%s", it.name))
        im.TextDisabled("%s", fmt.ctprintf("%s · %s", trs(KIND_LABEL[it.kind]), bytes_text(it.bytes)))
        im.TextDisabled("%s", fmt.ctprintf("%s", it.detail))
        im.EndTooltip()
    }
}

// Text clipped to a block, so a long key never spills into its neighbour.
@(private="file")
asset_label :: proc(dl: ^im.DrawList, p, clip_max: [2]f32, text: cstring, col: u32) {
    im.DrawList_PushClipRect(dl, p, clip_max, true)
    im.DrawList_AddText(dl, p, col, text)
    im.DrawList_PopClipRect(dl)
}

// The key without its directory: "assets/models/cars.gltf:police:0" → "cars.gltf:police:0".
@(private="file")
short_name :: proc(key: string) -> string {
    if i := strings.last_index_byte(key, '/'); i >= 0 do return key[i + 1:]
    return key
}

@(private="file")
kind_color :: proc(kind: Asset_Mem_Kind, shade: f32) -> u32 {
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
