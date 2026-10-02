package blimp

import "base:runtime"
import "core:log"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:path/filepath"
import "core:mem"
import "core:slice"
import vmem "core:mem/virtual"
import la "core:math/linalg"
import "core:image/png"
import "core:encoding/json"
import "core:hash/xxhash"
import "core:net"
import "lib:gltf2"
import "common"

Asset_System :: struct {
    meshes: [dynamic]Mesh,
    materials: [dynamic]Material,
    images: [dynamic]Image,

    mesh_ids: map[string]u32,
    material_ids: map[string]u32,
    image_ids: map[string]u32,
    image_contents: map[Image_Content]u32,   // embedded images by encoded content (add_embedded_image)

    models: map[string]Model,
    kits: [dynamic]Kit,   // every glTF that produced models, sorted by path

    vertex_indices: [dynamic]u32,
    vertex_positions: [dynamic]vec3,
    vertex_attributes: [dynamic]Vertex_Attributes,

    mesh_bvhs: []Mesh_BVH,
    material_albedo: []vec3,   // per material: linear colour × its texture's average, clamped below 1 (the baker's bounce colour)

    arena: vmem.Arena,
}
asset_system: Asset_System

Mesh :: struct {
    index_offset: u32,
    index_count: u32,
    vertex_offset: u32,
    vertex_count: u32,

    material: u32,
}

Material :: struct {
    color: rgba_f32,
    color_tex: u32,
}

Image :: struct {
    width, height: u32,
    format: Image_Format,
    pixels: []byte,
}

// A glTF file — a set of related models (CLAUDE.md → Assets) — plus its scene layout, which is
// what the editor shows when the kit is opened as a world. Display-only: copying a model out
// doesn't carry the kit transform.
Kit :: struct {
    path:  string,              // project-relative glTF path
    nodes: [dynamic]Kit_Node,   // one per mesh node in the glTF's default scene
}

Kit_Node :: struct {
    name:     string,   // glTF node name (falls back to the model name)
    model:    string,   // model key
    position: vec3,     // node world translation, engine space. Rotation/scale are baked into the mesh.
}

Model :: struct {
    key:    string,   // its own interned key, stored so callers can reference it without owning a copy
    meshes: [dynamic]u32,
}

Vertex_Attributes :: struct {
    color: rgba_f32,
    normal: vec3,
    uv0: vec2,
}

// Identifies an embedded image by its encoded bytes. A 64-bit hash plus the length makes a collision
// between two different textures negligible at kit counts.
Image_Content :: struct {
    hash: u64,
    size: int,
}

Image_Format :: enum {
    RGBA8,
    RGBA8_SRGB,
}

asset_system_init :: proc() {
    if err := vmem.arena_init_growing(&asset_system.arena); err != nil {
        log.panicf("Failed to init asset arena: %v", err)
    }
    context.allocator = vmem.arena_allocator(&asset_system.arena)

    asset_files := make([dynamic]os.File_Info, context.temp_allocator)
    if err := common.get_all_files("./assets_engine", &asset_files, context.temp_allocator); err != nil {
        log.errorf("Failed to scan ./assets_engine: %v", err)
    }
    if err := common.get_all_files("./assets", &asset_files, context.temp_allocator); err != nil {
        log.errorf("Failed to scan ./assets: %v", err)
    }

    // Default 1x1 textures, always at fixed slots so materials have a safe fallback.
    add_solid_image("black", {0, 0, 0, 255})
    add_solid_image("white", {255, 255, 255, 255})
    add_solid_image("gray",  {127, 127, 127, 255})

    // Default material (index 0): meshes with no glTF material resolve here.
    append(&asset_system.materials, Material{color = {1, 1, 1, 1}, color_tex = asset_system.image_ids["white"]})
    asset_system.material_ids["default"] = u32(len(asset_system.materials)) - 1

    // Textures are not scanned up front; each glTF imports the images it
    // references (embedded, or its own external files loaded on demand).
    for fi in asset_files {
        ext := strings.to_lower(filepath.ext(fi.fullpath), context.temp_allocator)
        switch ext {
            case ".gltf", ".glb": asset_system_import_gltf_models(fi.fullpath)
        }
    }
    slice.sort_by(asset_system.kits[:], proc(a, b: Kit) -> bool { return a.path < b.path })
    // More image keys than images means kits share textures (by path, or by embedded content).
    log.infof("Assets: %v kits, %v meshes, %v images under %v keys", len(asset_system.kits),
        len(asset_system.meshes), len(asset_system.images), len(asset_system.image_ids))

    asset_build_bvhs()
    asset_build_albedos()
}

asset_system_update :: proc() {
}

asset_system_shutdown :: proc() {
    vmem.arena_destroy(&asset_system.arena)
    asset_system = {}
}

// The light baker's surface colour per material (docs/rendering.md → Lighting): its colour times the average
// of its colour texture, averaged in linear, clamped to MAX_BAKE_ALBEDO so bounces converge.
MAX_BAKE_ALBEDO :: 0.9

asset_build_albedos :: proc() {
    lut: [256]f32   // sRGB byte → linear
    for i in 0..<256 do lut[i] = srgb_to_linear(f32(i) / 255)

    arena := vmem.arena_allocator(&asset_system.arena)
    asset_system.material_albedo = make([]vec3, len(asset_system.materials), arena)
    for mat, i in asset_system.materials {
        img := asset_system.images[mat.color_tex]
        sum: [3]f64
        n := len(img.pixels) / 4
        for p in 0..<n {
            px := img.pixels[4*p:][:3]
            for c in 0..<3 do sum[c] += f64(img.format == .RGBA8_SRGB ? lut[px[c]] : f32(px[c]) / 255)
        }
        avg := n > 0 ? vec3{f32(sum[0]), f32(sum[1]), f32(sum[2])} / f32(n) : vec3{1, 1, 1}
        a := avg * mat.color.rgb
        asset_system.material_albedo[i] = {min(a.x, MAX_BAKE_ALBEDO), min(a.y, MAX_BAKE_ALBEDO), min(a.z, MAX_BAKE_ALBEDO)}
    }
}

asset_build_bvhs :: proc() {
    arena := vmem.arena_allocator(&asset_system.arena)
    asset_system.mesh_bvhs = make([]Mesh_BVH, len(asset_system.meshes), arena)
    for m, i in asset_system.meshes {
        asset_system.mesh_bvhs[i] = bvh_build_for_mesh(m, arena)
    }
    free_all(context.temp_allocator)
}

// Total bytes of loaded asset payload (geometry + textures + tables), excluding
// lookup maps and arena bookkeeping.
asset_system_assets_size :: proc() -> (total: int) {
    total += len(asset_system.vertex_indices)    * size_of(u32)
    total += len(asset_system.vertex_positions)  * size_of(vec3)
    total += len(asset_system.vertex_attributes) * size_of(Vertex_Attributes)
    total += len(asset_system.meshes)    * size_of(Mesh)
    total += len(asset_system.materials) * size_of(Material)
    total += len(asset_system.images)    * size_of(Image)
    for img in asset_system.images do total += len(img.pixels)
    return
}

// Returns the interned (permanent) key string for a model, so callers can store the
// reference without owning a copy — model keys live in the asset arena, which outlives
// every level. An unknown key is cloned into the asset arena so a broken scene
// reference stays a valid string (the renderer warns on it at draw time).
asset_model_key :: proc(key: string) -> string {
    if model, ok := asset_system.models[key]; ok {
        return model.key
    }
    return strings.clone(key, vmem.arena_allocator(&asset_system.arena))
}

asset_system_import_gltf_models :: proc(path: string) {
    // Load the glTF and all its scratch into a temp-arena checkpoint, reclaimed
    // on return. We can't use gltf2.unload: it frees against context.allocator
    // (the asset arena here), not the allocator the data was loaded with, so it
    // wouldn't free anything. Rolling back the temp arena also covers the image
    // index table, key scratch, and decoded-image staging allocated below.
    temp_mark := vmem.arena_temp_begin(&app.allocators.temp_arena)
    defer vmem.arena_temp_end(temp_mark)

    data, error := gltf2.load_from_file(path, context.temp_allocator)
    if error != nil {
        switch err in error {
            case gltf2.JSON_Error:
                log.errorf("Failed to load gltf, json error. File: %v, error: %v", path, err.type)
            case gltf2.GLTF_Error:
                log.errorf("Failed to load gltf, gltf error. File: %v, error: %v, param: %v", path, err.type, err.param.name)
        }
        return
    }

    if len(data.meshes) <= 0 {
        return
    }

    file_key := asset_key(path, context.temp_allocator)

    /* --------------------- Resolve glTF images to asset images -------------------- */
    // image_indices[gltf image index] -> our global asset image index.
    image_indices := make([]u32, len(data.images), context.temp_allocator)
    for &idx in image_indices do idx = asset_system.image_ids["white"]
    for image, i in data.images {
        uri := gltf_image_uri(data, i)
        if uri != "" && !strings.has_prefix(uri, "data:") {
            // External file: keyed by its project path, so every glTF that references it shares one
            // image.
            resolved, in_project := gltf_image_path(path, uri)
            if !in_project {
                log.warnf("Texture '%v' in %v is outside the project; using white.", uri, path)
                continue
            }
            image_key := asset_key(resolved, context.temp_allocator)
            idx, found := asset_system.image_ids[image_key]
            if !found {
                if bytes, read := image.uri.([]byte); read {
                    // The loader already read the file (it can't when the URI has escapes).
                    idx, found = add_encoded_image(strings.clone(image_key), bytes)
                } else {
                    idx, found = asset_system_import_png_image(resolved)
                }
            }
            if found {
                image_indices[i] = idx
            } else {
                log.warnf("Cannot load gltf texture '%v' (%v) in %v; using white.", uri, resolved, path)
            }
            continue
        }

        // Embedded: a data URI the loader decoded, or a buffer view (typical for .glb).
        encoded, _ := image.uri.([]byte)
        if bv_idx, has_view := image.buffer_view.(gltf2.Integer); has_view && encoded == nil {
            encoded = gltf_buffer_view_bytes(data, bv_idx)
        }
        if encoded == nil {
            log.warnf("gltf image %v has no readable uri or buffer_view in %v; using white.", i, path)
            continue
        }
        img_name := image.name.(string) or_else fmt.tprintf("image%v", i)
        if idx, ok := add_embedded_image(fmt.aprintf("%v:%v", file_key, img_name), encoded); ok {
            image_indices[i] = idx
        }
    }

    /* ------------------------------- Materials ------------------------------ */
    material_base := u32(len(asset_system.materials))
    for mat, i in data.materials {
        mat_name := mat.name.(string) or_else fmt.tprintf("%v", i)
        mat_key := fmt.aprintf("%v:%v", file_key, mat_name)

        material := Material{color = {1, 1, 1, 1}, color_tex = asset_system.image_ids["white"]}
        if mr, ok := mat.metallic_roughness.(gltf2.Material_Metallic_Roughness); ok {
            material.color = mr.base_color_factor
            if tex_info, tex_ok := mr.base_color_texture.(gltf2.Texture_Info); tex_ok {
                if int(tex_info.index) < len(data.textures) {
                    if src, src_ok := data.textures[tex_info.index].source.(gltf2.Integer); src_ok {
                        material.color_tex = image_indices[src]
                    }
                }
            }
        }

        append(&asset_system.materials, material)
        asset_system.material_ids[mat_key] = u32(len(asset_system.materials)) - 1
    }

    /* --------------------------- Node transforms ---------------------------- */
    // The glTF bakes the Z-up->Y-up conversion into node matrices, so each mesh's node
    // rotation/scale — composed down the scene hierarchy — is baked into its vertices. The
    // node's world *translation* is not baked: it becomes the kit's display layout
    // (Kit_Node.position), and entity transforms do placement. The X-negate plus winding swap
    // below yields Y-up, left-handed, +Z forward, CW front faces. A mesh referenced by several
    // nodes bakes the last one's rotation/scale (geometry is stored once, not per node).
    node_world, node_reached := gltf_world_matrices(data, context.temp_allocator)
    mesh_matrices := make([]matrix[4, 4]f32, len(data.meshes), context.temp_allocator)
    for &m in mesh_matrices do m = 1
    for node, ni in data.nodes {
        if mi, ok := node.mesh.(gltf2.Integer); ok && node_reached[ni] {
            mesh_matrices[mi] = node_world[ni]
        }
    }
    mesh_model_keys := make([]string, len(data.meshes), context.temp_allocator)   // "" = mesh not imported

    /* --------------------------- Models and meshes -------------------------- */
    for gltf_mesh, gltf_mesh_idx in data.meshes {
        node_mat := mesh_matrices[gltf_mesh_idx]
        model_name := gltf_mesh.name.(string) or_else fmt.tprintf("%v", gltf_mesh_idx)
        model_key := fmt.aprintf("%v:%v", file_key, model_name)

        if model_key in asset_system.models {
            log.errorf("Duplicate model key '%v'. Rename the file or the mesh. File: %v", model_key, path)
            continue
        }

        model: Model
        model.key = model_key   // model_key lives in the asset arena (permanent)
        model.meshes = make([dynamic]u32, len(gltf_mesh.primitives))

        for gltf_prim, gltf_prim_idx in gltf_mesh.primitives {
            mesh_key := fmt.aprintf("%v:%v", model_key, gltf_prim_idx)

            index_acc_idx, has_indices := gltf_prim.indices.(gltf2.Integer)
            position_acc_idx, has_pos := gltf_prim.attributes["POSITION"]
            color_acc_idx, has_color := gltf_prim.attributes["COLOR_0"]
            normal_acc_idx, has_normal := gltf_prim.attributes["NORMAL"]
            uv_acc_idx, has_uv := gltf_prim.attributes["TEXCOORD_0"]

            mesh: Mesh
            /* --------------------------------- Indices -------------------------------- */
            if !has_indices {
                log.errorf("No indices in gltf primitive. File: %v, mesh: %v", path, model_name)
                return
            }

            mesh.index_offset = u32(len(asset_system.vertex_indices))
            mesh.index_count = data.accessors[index_acc_idx].count
            resize(&asset_system.vertex_indices, int(mesh.index_offset + mesh.index_count))

            #partial switch indices in gltf2.buffer_slice(data, index_acc_idx) {
                case []u8:  for index, i in indices do asset_system.vertex_indices[mesh.index_offset + u32(i)] = u32(index)
                case []u16: for index, i in indices do asset_system.vertex_indices[mesh.index_offset + u32(i)] = u32(index)
                case []u32: for index, i in indices do asset_system.vertex_indices[mesh.index_offset + u32(i)] = index
                case: log.errorf("Unsupported gltf indices format. File: %v", path)
            }

            // Reverse winding: the X negate below mirrors geometry (RH -> LH), and this
            // swap restores CW front faces for the rasterizer (FrontCounterClockwise=false,
            // cull BACK). Reflection + swap together = correct facing (verified in-engine).
            for t := u32(0); t + 2 < mesh.index_count; t += 3 {
                a := mesh.index_offset + t
                asset_system.vertex_indices[a + 1], asset_system.vertex_indices[a + 2] =
                    asset_system.vertex_indices[a + 2], asset_system.vertex_indices[a + 1]
            }

            /* -------------------------------- Positions ------------------------------- */
            if !has_pos {
                log.errorf("No POSITION attribute in gltf primitive. File: %v, mesh: %v", path, model_name)
                return
            }

            mesh.vertex_offset = u32(len(asset_system.vertex_positions))
            mesh.vertex_count = data.accessors[position_acc_idx].count
            resize(&asset_system.vertex_positions, int(mesh.vertex_offset + mesh.vertex_count))

            positions, ok := gltf2.buffer_slice(data, position_acc_idx).([][3]f32)
            if !ok {
                log.errorf("Unsupported gltf positions format. File: %v", path)
                return
            }

            for pos, i in positions {
                p := node_mat * [4]f32{pos.x, pos.y, pos.z, 0}   // rotation/scale only (w=0 drops translation)
                asset_system.vertex_positions[mesh.vertex_offset + u32(i)] = {-p.x, p.y, p.z}   // negate X: RH -> LH (keeps +Z forward)
            }

            /* ------------------------------- Attributes ------------------------------- */
            resize(&asset_system.vertex_attributes, int(mesh.vertex_offset + mesh.vertex_count))

            // Color
            if has_color {
                #partial switch colors in gltf2.buffer_slice(data, color_acc_idx) {
                    case [][3]u8: {
                        for clr, i in colors {
                            asset_system.vertex_attributes[mesh.vertex_offset + u32(i)].color.rgb = cast([3]f32)clr
                            asset_system.vertex_attributes[mesh.vertex_offset + u32(i)].color.a = 1
                        }
                    }
                    case [][4]u8: {
                        for clr, i in colors do asset_system.vertex_attributes[mesh.vertex_offset + u32(i)].color = cast([4]f32)clr
                    }
                    case [][3]f32: {
                        for clr, i in colors {
                            asset_system.vertex_attributes[mesh.vertex_offset + u32(i)].color.rgb = clr
                            asset_system.vertex_attributes[mesh.vertex_offset + u32(i)].color.a = 1
                        }
                    }
                    case [][4]f32: {
                        for clr, i in colors do asset_system.vertex_attributes[mesh.vertex_offset + u32(i)].color = clr
                    }
                    case: {
                        log.warnf("Unsupported gltf color attribute format. Fallback to default. File: %v", path)
                        for i in mesh.vertex_offset..<mesh.vertex_offset + mesh.vertex_count do asset_system.vertex_attributes[i].color = {1, 1, 1, 1}
                    }
                }
            } else {
                for i in mesh.vertex_offset..<mesh.vertex_offset + mesh.vertex_count do asset_system.vertex_attributes[i].color = {1, 1, 1, 1}
            }

            // Normal
            if has_normal {
                normals, normal_ok := gltf2.buffer_slice(data, normal_acc_idx).([][3]f32)
                if normal_ok {
                    for nm, i in normals {
                        n := node_mat * [4]f32{nm.x, nm.y, nm.z, 0}
                        asset_system.vertex_attributes[mesh.vertex_offset + u32(i)].normal = la.normalize([3]f32{-n.x, n.y, n.z})
                    }
                } else {
                    log.warnf("Unsupported gltf normal attribute format. Fallback to default. File: %v", path)
                    for i in mesh.vertex_offset..<mesh.vertex_offset + mesh.vertex_count do asset_system.vertex_attributes[i].normal = {0, 1, 0}
                }
            } else {
                log.warnf("Can't find normal attribute in gltf. Fallback to default. File: %v", path)
                for i in mesh.vertex_offset..<mesh.vertex_offset + mesh.vertex_count do asset_system.vertex_attributes[i].normal = {0, 1, 0}
            }

            // UV
            if has_uv {
                uv0s, uv0_ok := gltf2.buffer_slice(data, uv_acc_idx).([][2]f32)
                if uv0_ok {
                    for uv0, i in uv0s do asset_system.vertex_attributes[mesh.vertex_offset + u32(i)].uv0 = uv0
                } else {
                    log.warnf("Unsupported gltf uv0 attribute format. Fallback to default. File: %v", path)
                    for i in mesh.vertex_offset..<mesh.vertex_offset + mesh.vertex_count do asset_system.vertex_attributes[i].uv0 = {0, 0}
                }
            } else {
                for i in mesh.vertex_offset..<mesh.vertex_offset + mesh.vertex_count do asset_system.vertex_attributes[i].uv0 = {0, 0}
            }

            // Material
            mesh.material = asset_system.material_ids["default"]
            if mat_idx, has_mat := gltf_prim.material.(gltf2.Integer); has_mat {
                mesh.material = material_base + mat_idx
            }

            append(&asset_system.meshes, mesh)
            mesh_index := u32(len(asset_system.meshes)) - 1
            asset_system.mesh_ids[mesh_key] = mesh_index
            model.meshes[gltf_prim_idx] = mesh_index
        } // End loop gltf prim

        asset_system.models[model_key] = model
        mesh_model_keys[gltf_mesh_idx] = model_key
    } // End loop gltf mesh

    // A glTF with meshes is a kit (CLAUDE.md → Assets). Its scene's mesh nodes are the display
    // layout the editor reproduces when the kit is opened as a world.
    kit := Kit{path = strings.clone(file_key)}
    for node, ni in data.nodes {
        mi, has_mesh := node.mesh.(gltf2.Integer)
        if !has_mesh || !node_reached[ni] || mesh_model_keys[mi] == "" do continue
        w := node_world[ni]
        append(&kit.nodes, Kit_Node{
            name     = strings.clone(node.name.(string) or_else mesh_model_keys[mi][len(file_key) + 1:]),
            model    = mesh_model_keys[mi],
            position = {-w[0, 3], w[1, 3], w[2, 3]},   // glTF RH -> engine LH: negate X, like the vertices
        })
    }
    append(&asset_system.kits, kit)
}

// World matrix of every node reachable from the glTF's default scene (or, if it declares no scenes,
// from every parentless node), composed parent -> child. reached[i] is false for nodes outside that
// scene; their matrix stays identity.
@(private="file")
gltf_world_matrices :: proc(data: ^gltf2.Data, allocator: runtime.Allocator) -> (world: []matrix[4, 4]f32, reached: []bool) {
    world   = make([]matrix[4, 4]f32, len(data.nodes), allocator)
    reached = make([]bool, len(data.nodes), allocator)
    for &m in world do m = 1

    if len(data.scenes) > 0 {
        for root in data.scenes[data.scene.? or_else 0].nodes do gltf_visit_node(data, root, 1, world, reached)
    } else {
        is_child := make([]bool, len(data.nodes), context.temp_allocator)
        for n in data.nodes do for c in n.children do is_child[c] = true
        for _, i in data.nodes do if !is_child[i] do gltf_visit_node(data, gltf2.Integer(i), 1, world, reached)
    }
    return
}

@(private="file")
gltf_visit_node :: proc(data: ^gltf2.Data, idx: gltf2.Integer, parent: matrix[4, 4]f32, world: []matrix[4, 4]f32, reached: []bool) {
    if reached[idx] do return   // malformed graph (node listed twice / cycle): visit once
    m := parent * gltf_node_matrix(data.nodes[idx])
    world[idx], reached[idx] = m, true
    for c in data.nodes[idx].children do gltf_visit_node(data, c, m, world, reached)
}

asset_system_import_png_image :: proc(path: string) -> (index: u32, ok: bool) {
    // Decode into scratch; keep only a tightly-owned copy in the asset arena.
    img, err := png.load(path, {.alpha_add_if_missing}, context.temp_allocator)
    if err != nil {
        log.errorf("Failed to import png, path: %v, err: %v", path, err)
        return 0, false
    }
    defer png.destroy(img)

    // Key by project-relative path so a shared texture is imported only once.
    return add_decoded_image(asset_key(path), img), true
}

@(private="file")
add_solid_image :: proc(key: string, color: [4]u8) {
    image := Image{format = .RGBA8_SRGB, width = 1, height = 1, pixels = make([]byte, 4)}
    image.pixels[0] = color[0]
    image.pixels[1] = color[1]
    image.pixels[2] = color[2]
    image.pixels[3] = color[3]
    append(&asset_system.images, image)
    asset_system.image_ids[key] = u32(len(asset_system.images)) - 1
}

// Object-space AABB over every vertex of a model's meshes. Computed on demand (cheap at kit sizes);
// cache it in the mesh record if it ever shows up in a profile.
model_bounds :: proc(model: Model) -> (lo, hi: vec3) {
    lo = { max(f32), max(f32), max(f32) }
    hi = { min(f32), min(f32), min(f32) }
    for mesh_idx in model.meshes {
        m := asset_system.meshes[mesh_idx]
        for i in m.vertex_offset ..< m.vertex_offset + m.vertex_count {
            p := asset_system.vertex_positions[i]
            lo = {min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)}
            hi = {max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)}
        }
    }
    return
}

// Working-directory-relative, forward-slash form of a path, used as the file
// portion of every asset key. get_all_files returns absolute paths, so we make
// them relative to the CWD (project root) — identical across machines and OSes
// and safe to hand-author in level files (find-and-replace on rename). Also used
// for scene file paths (scene_find_files), which follow the same convention.
asset_key :: proc(path: string, allocator := context.allocator) -> string {
    cwd, _ := os.get_working_directory(context.temp_allocator)
    rel := path
    if r, err := filepath.rel(cwd, path, context.temp_allocator); err == nil {
        rel = r
    }
    // replace_all only allocates when it actually replaced something; with no backslash (a file in
    // the project root) it returns `rel` itself, which lives in temp. Always hand back an owned copy.
    key, allocated := strings.replace_all(rel, "\\", "/", allocator)
    if !allocated do key = strings.clone(key, allocator)
    return key
}

// A glTF node's local transform. A node uses either `matrix` (mat set, TRS default)
// or TRS (mat identity), so `mat * T*R*S` is correct for both.
@(private="file")
gltf_node_matrix :: proc(n: gltf2.Node) -> matrix[4, 4]f32 {
    t := la.matrix4_translate_f32(n.translation)
    r := la.matrix4_from_quaternion_f32(n.rotation)
    s := la.matrix4_scale_f32(n.scale)
    return n.mat * t * r * s
}

// Copies a decoded image into the asset arena and registers it under key.
@(private="file")
add_decoded_image :: proc(key: string, img: ^png.Image) -> u32 {
    image: Image
    image.width = u32(img.width)
    image.height = u32(img.height)
    image.format = .RGBA8_SRGB
    image.pixels = make([]byte, len(img.pixels.buf))
    mem.copy(raw_data(image.pixels), raw_data(img.pixels.buf), len(img.pixels.buf))

    append(&asset_system.images, image)
    index := u32(len(asset_system.images)) - 1
    asset_system.image_ids[key] = index
    return index
}

// Decodes an encoded image (PNG) held in memory — a glTF data-URI, an
// external file the loader already read, or a .glb buffer-view blob.
@(private="file")
add_encoded_image :: proc(key: string, encoded: []byte) -> (index: u32, ok: bool) {
    img, err := png.load_from_bytes(encoded, {.alpha_add_if_missing}, context.temp_allocator)
    if err != nil {
        log.errorf("Failed to decode embedded image '%v': %v", key, err)
        return 0, false
    }
    defer png.destroy(img)
    return add_decoded_image(key, img), true
}

// Embedded images have no path to share by, and 3ds Max embeds every texture into every .glb, so
// they're shared by content instead: the first copy of some encoded bytes is decoded, and a later one
// only registers its own key for the same image (skipping the decode and the VRAM copy).
@(private="file")
add_embedded_image :: proc(key: string, encoded: []byte) -> (index: u32, ok: bool) {
    content := Image_Content{hash = xxhash.XXH3_64_default(encoded), size = len(encoded)}
    if idx, found := asset_system.image_contents[content]; found {
        asset_system.image_ids[key] = idx
        return idx, true
    }
    index = add_encoded_image(key, encoded) or_return
    asset_system.image_contents[content] = index
    return index, true
}

// The file an external glTF image URI points at, as a path under the project root (the working
// directory). URIs are percent-encoded ("my%20tex.png") and normally relative to the glTF. A DCC
// without a project folder set writes absolute ones ("E:\...", "file:///E:/..."), possibly from
// another machine, so those are re-rooted at their first assets/ or assets_engine/ directory that
// exists here. Not ok when the file lives outside the project.
@(private="file")
gltf_image_path :: proc(gltf_path, uri: string) -> (path: string, ok: bool) {
    p, decoded := net.percent_decode(uri, context.temp_allocator)
    if !decoded do p = uri
    p, _ = strings.replace_all(p, "\\", "/", context.temp_allocator)
    if strings.has_prefix(p, "file://") {
        p = p[len("file://"):]
        if len(p) > 2 && p[0] == '/' && p[2] == ':' do p = p[1:] // "/E:/x" -> "E:/x"
    }
    if !filepath.is_abs(p) {
        joined, _ := filepath.join({filepath.dir(gltf_path), p}, context.temp_allocator)
        return joined, true
    }
    lower := strings.to_lower(p, context.temp_allocator)
    for i := 0; i < len(lower); i += 1 {
        for root in ([]string{"assets/", "assets_engine/"}) {
            if i > 0 && lower[i - 1] != '/' do continue
            if !strings.has_prefix(lower[i:], root) do continue
            // Canonical root casing so "Assets/x.png" and "assets/x.png" key the same image.
            candidate := strings.concatenate({root, p[i + len(root):]}, context.temp_allocator)
            if os.exists(candidate) do return candidate, true
        }
    }
    return "", false
}

// The original `uri` string of a glTF image, or "". When the loader can read an external file it
// replaces Image.uri with the bytes, dropping the path; the parsed JSON it keeps still has it.
@(private="file")
gltf_image_uri :: proc(data: ^gltf2.Data, image_idx: int) -> string {
    root, _ := data.json_value.(json.Object)
    images, _ := root["images"].(json.Array)
    if image_idx >= len(images) do return ""
    image, _ := images[image_idx].(json.Object)
    uri, _ := image["uri"].(string)
    return uri
}

// Raw bytes backing a buffer view, used for .glb-embedded images. The backing
// buffer is []byte for both .glb (binary chunk) and .gltf (external .bin the
// loader auto-read).
@(private="file")
gltf_buffer_view_bytes :: proc(data: ^gltf2.Data, bv_idx: gltf2.Integer) -> []byte {
    bv := data.buffer_views[bv_idx]
    raw, ok := data.buffers[bv.buffer].uri.([]byte)
    if !ok do return nil
    start := int(bv.byte_offset)
    end := start + int(bv.byte_length)
    if end > len(raw) do return nil
    return raw[start:end]
}
