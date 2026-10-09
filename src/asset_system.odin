package blimp

import "base:runtime"
import "core:log"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:reflect"
import "core:path/filepath"
import "core:mem"
import "core:slice"
import vmem "core:mem/virtual"
import la "core:math/linalg"
import "core:image"
// Imported only to register their decoders with core:image, which picks one by the file signature.
import _ "core:image/png"
import _ "core:image/jpeg"
import "core:encoding/json"
import "core:hash/xxhash"
import "core:net"
import "core:c"
import "lib:gltf2"
import b3 "vendor:box3d"
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
    vertex_skins: [dynamic]Skin_Vertex,   // skinned meshes only, from Mesh.skin_offset (asset_anim.odin)

    skeletons: [dynamic]Skeleton,
    clips: [dynamic]Clip,

    mesh_bvhs: []Mesh_BVH,
    collision: map[string]^b3.MeshData,          // model key → its authored collision (the kit's <model>_col mesh, cooked); Box3D owns the data
    render_collision: map[string]^b3.MeshData,   // model key → its render triangles cooked for collision, on first use (asset_render_collision)
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
    skin_offset: u32,   // into vertex_skins, parallel to the vertices; NO_SKIN for a static mesh
    _pad: [2]u32,
}
#assert(size_of(Mesh) == 32)   // = Mesh in scene.slang and shadow.slang (uploaded as is)

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
    character: bool,            // a model in it is skinned: the editor lists it under Characters, not Kits
}

Kit_Node :: struct {
    name:     string,   // glTF node name (falls back to the model name)
    model:    string,   // model key
    position: vec3,     // node world translation, engine space. Rotation/scale are baked into the mesh.
}

Model :: struct {
    key:      string,   // its own interned key, stored so callers can reference it without owning a copy
    meshes:   [dynamic]u32,
    skeleton: u32,      // asset_system.skeletons index, NO_SKELETON if unskinned
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

// Asset keys handed out to entities (model and texture references), interned in their own arena. It
// outlives the asset arena, which a hot reload throws away and rebuilds (app_hot_reload.odin), so an
// entity's model string, and every undo snapshot and clipboard copy of it, stays valid across reloads.
Asset_Keys :: struct {
    strings: map[string]string,   // key → its interned copy (both the same string)
    arena:   vmem.Arena,
}
asset_keys: Asset_Keys

// The permanent copy of `key`. A key nothing loaded under (a broken scene reference) is interned too,
// so it stays a valid string; the renderer warns on it at draw time.
asset_intern :: proc(key: string) -> string {
    if s, ok := asset_keys.strings[key]; ok do return s
    arena := vmem.arena_allocator(&asset_keys.arena)
    if asset_keys.strings == nil do asset_keys.strings = make(map[string]string, arena)
    s := strings.clone(key, arena)
    asset_keys.strings[s] = s
    return s
}

// Interns (asset_intern) every asset key in `v`, a struct, nested structs included: its string fields tagged
// `widget:model`, `widget:texture` or `widget:sound`, the asset pickers' tags. The one way keys are kept, for
// anything decoded from text (deserialize_value leaves strings in temp memory, gone next frame): an entity in
// world_add, World_Settings on scene load. A new key field, a schema-editor one too, needs only its tag. Pass
// the variable itself: `v` aliases it, as with struct_field_by_path.
asset_intern_keys :: proc(v: any) {
    for i in 0 ..< reflect.struct_field_count(v.id) {
        sf    := reflect.struct_field_at(v.id, i)
        field := reflect.struct_field_value(v, sf)
        if type_is_struct(sf.type.id) {
            asset_intern_keys(field)
        } else if key, is_string := field.(string); is_string && asset_key_field(sf.tag) {
            (^string)(field.data)^ = asset_intern(key)
        }
    }
}

@(private="file")
asset_key_field :: proc(tag: reflect.Struct_Tag) -> bool {
    for t in strings.split(string(tag), ",", context.temp_allocator) {
        switch strings.trim_space(t) {
        case "widget:model", "widget:texture", "widget:sound": return true
        }
    }
    return false
}

// Throws every asset away and loads them again from disk. Only the asset part: app_reload_assets
// (app_lifecycle.odin) rebuilds the GPU copies and play worlds' physics around it.
asset_system_reload :: proc() {
    asset_collision_destroy()
    vmem.arena_destroy(&asset_system.arena)
    asset_system = {}
    asset_system_load()
}

@(private="file")
asset_collision_destroy :: proc() {
    for _, m in asset_system.collision do b3.DestroyMesh(m)
    for _, m in asset_system.render_collision do if m != nil do b3.DestroyMesh(m)
}

// A model's own triangles as collision (an entity's `collision = Render_Mesh`). Cooked the first time an
// entity asks and kept until the assets reload; nil for an unknown model or one Box3D can't build.
asset_render_collision :: proc(key: string) -> ^b3.MeshData {
    if m, cached := asset_system.render_collision[key]; cached do return m
    model, ok := asset_system.models[key]
    m := ok ? asset_cook_mesh(key, model, {}) : nil
    asset_system.render_collision[asset_intern(key)] = m   // a nil is cached too, so it's tried once
    return m
}

// Loads every asset from disk: at init, and again on a hot reload (asset_system_reload).
asset_system_load :: proc() {
    if err := vmem.arena_init_growing(&asset_system.arena); err != nil {
        log.panicf("Failed to init asset arena: %v", err)
    }
    context.allocator = vmem.arena_allocator(&asset_system.arena)
    asset_system.render_collision = make(map[string]^b3.MeshData)   // filled during play, so it needs the arena allocator now

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

    // Every PNG and JPEG loads, keyed by its project path, whether or not a glTF uses it (a sky, say). First, so
    // a glTF that references one finds it by key (asset_system_import_gltf_models) instead of decoding it again.
    for fi in asset_files {
        switch strings.to_lower(filepath.ext(fi.fullpath), context.temp_allocator) {
            case ".png", ".jpg", ".jpeg": asset_system_import_image(fi.fullpath)
        }
    }
    // Then the kits, with their embedded images (.glb, data URIs) and any external one outside the scan.
    for fi in asset_files {
        ext := strings.to_lower(filepath.ext(fi.fullpath), context.temp_allocator)
        switch ext {
            case ".gltf", ".glb": asset_system_import_gltf_models(fi.fullpath)
        }
    }
    slice.sort_by(asset_system.kits[:], proc(a, b: Kit) -> bool { return a.path < b.path })
    // More image keys than images means kits share textures (by path, or by embedded content).
    log.infof("Assets: %v kits, %v meshes, %v images under %v keys, %v collision models, %v skeletons, %v clips", len(asset_system.kits),
        len(asset_system.meshes), len(asset_system.images), len(asset_system.image_ids), len(asset_system.collision),
        len(asset_system.skeletons), len(asset_system.clips))

    asset_build_bvhs()
    asset_build_albedos()
}

asset_system_shutdown :: proc() {
    asset_collision_destroy()
    vmem.arena_destroy(&asset_system.arena)
    asset_system = {}
    vmem.arena_destroy(&asset_keys.arena)
    asset_keys = {}
}

// The light baker's surface colour per material (claude/rendering.md → Lighting): its colour times the average
// of its colour texture, averaged in linear, clamped to MAX_BAKE_ALBEDO so bounces converge.
MAX_BAKE_ALBEDO :: 0.9

asset_build_albedos :: proc() {
    srgb_lut, unorm_lut: [256]f32   // byte → linear
    for i in 0..<256 do srgb_lut[i]  = srgb_to_linear(f32(i) / 255)
    for i in 0..<256 do unorm_lut[i] = f32(i) / 255

    // Each image's average once: materials share textures, and the images are large.
    image_avg := make([]vec3, len(asset_system.images), context.temp_allocator)
    for img, i in asset_system.images {
        lut := img.format == .RGBA8_SRGB ? &srgb_lut : &unorm_lut
        sum: [3]f64
        n := len(img.pixels) / 4
        for p in 0..<n {
            px := img.pixels[4*p:][:3]
            sum[0] += f64(lut[px[0]])
            sum[1] += f64(lut[px[1]])
            sum[2] += f64(lut[px[2]])
        }
        image_avg[i] = n > 0 ? vec3{f32(sum[0]), f32(sum[1]), f32(sum[2])} / f32(n) : vec3{1, 1, 1}
    }

    arena := vmem.arena_allocator(&asset_system.arena)
    asset_system.material_albedo = make([]vec3, len(asset_system.materials), arena)
    for mat, i in asset_system.materials {
        a := image_avg[mat.color_tex] * mat.color.rgb
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
    if !gltf_drop_packed_strides(data, path) do return

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
                    idx, found = asset_system_import_image(resolved)
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
    // A skinned mesh ignores its node (glTF): its skin's rest pose places it instead (asset_anim.odin).
    skins := asset_import_skeletons(data, path, file_key, node_world, node_reached)
    mesh_skins := make([]int, len(data.meshes), context.temp_allocator)   // glTF skin per mesh, -1 = static
    for &s in mesh_skins do s = -1
    for node, ni in data.nodes {
        if mi, ok := node.mesh.(gltf2.Integer); ok && node_reached[ni] {
            mesh_matrices[mi] = node_world[ni]
            if si, skinned := node.skin.?; skinned && skins[si].skeleton != NO_SKELETON do mesh_skins[mi] = int(si)
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
        model.key = asset_intern(model_key)   // survives a reload (asset_keys)
        model.meshes = make([dynamic]u32, len(gltf_mesh.primitives))
        model.skeleton = NO_SKELETON
        skin := mesh_skins[gltf_mesh_idx]
        if skin >= 0 do model.skeleton = skins[skin].skeleton

        for gltf_prim, gltf_prim_idx in gltf_mesh.primitives {
            mesh_key := fmt.aprintf("%v:%v", model_key, gltf_prim_idx)

            index_acc_idx, has_indices := gltf_prim.indices.(gltf2.Integer)
            position_acc_idx, has_pos := gltf_prim.attributes["POSITION"]
            color_acc_idx, has_color := gltf_prim.attributes["COLOR_0"]
            normal_acc_idx, has_normal := gltf_prim.attributes["NORMAL"]
            uv_acc_idx, has_uv := gltf_prim.attributes["TEXCOORD_0"]

            mesh: Mesh
            mesh.skin_offset = NO_SKIN
            if !has_pos {
                log.errorf("No POSITION attribute in gltf primitive. File: %v, mesh: %v", path, model_name)
                return
            }

            /* --------------------------------- Indices -------------------------------- */
            mesh.index_offset = u32(len(asset_system.vertex_indices))
            if has_indices {
                mesh.index_count = data.accessors[index_acc_idx].count
                resize(&asset_system.vertex_indices, int(mesh.index_offset + mesh.index_count))

                #partial switch indices in gltf2.buffer_slice(data, index_acc_idx) {
                    case []u8:  for index, i in indices do asset_system.vertex_indices[mesh.index_offset + u32(i)] = u32(index)
                    case []u16: for index, i in indices do asset_system.vertex_indices[mesh.index_offset + u32(i)] = u32(index)
                    case []u32: for index, i in indices do asset_system.vertex_indices[mesh.index_offset + u32(i)] = index
                    case: log.errorf("Unsupported gltf indices format. File: %v", path)
                }
            } else {   // non-indexed: every three vertices are a triangle
                mesh.index_count = data.accessors[position_acc_idx].count
                for i in 0..<mesh.index_count do append(&asset_system.vertex_indices, i)
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
            mesh.vertex_offset = u32(len(asset_system.vertex_positions))
            mesh.vertex_count = data.accessors[position_acc_idx].count
            resize(&asset_system.vertex_positions, int(mesh.vertex_offset + mesh.vertex_count))

            positions, ok := gltf2.buffer_slice(data, position_acc_idx).([][3]f32)
            if !ok {
                log.errorf("Unsupported gltf positions format. File: %v", path)
                return
            }

            // A skinned vertex is baked into its rest pose, so drawing it unskinned shows that pose.
            skin_bind: []mat4
            if skin >= 0 do mesh.skin_offset, skin_bind = asset_import_skin_vertices(data, gltf_prim, skins[skin], mesh.vertex_count, path)
            for pos, i in positions {
                p := skin_bind != nil ? skin_bind[i] * [4]f32{pos.x, pos.y, pos.z, 1} : node_mat * [4]f32{pos.x, pos.y, pos.z, 0}   // rotation/scale only (w=0 drops translation)
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
                        n := (skin_bind != nil ? skin_bind[i] : node_mat) * [4]f32{nm.x, nm.y, nm.z, 0}
                        asset_system.vertex_attributes[mesh.vertex_offset + u32(i)].normal = la.normalize([3]f32{-n.x, n.y, n.z})
                    }
                } else {
                    log.warnf("Unsupported gltf normal attribute format. Fallback to default. File: %v", path)
                    for i in mesh.vertex_offset..<mesh.vertex_offset + mesh.vertex_count do asset_system.vertex_attributes[i].normal = {0, 1, 0}
                }
            } else {
                mesh_compute_normals(mesh)
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
    // Collision models (<model>_col) aren't laid out: they're never drawn.
    kit := Kit{path = strings.clone(file_key)}
    model_pos := make(map[string]vec3, context.temp_allocator)   // where the first node placing each model sits
    for node, ni in data.nodes {
        mi, has_mesh := node.mesh.(gltf2.Integer)
        if !has_mesh || !node_reached[ni] || mesh_model_keys[mi] == "" do continue
        w := node_world[ni]
        pos := vec3{-w[0, 3], w[1, 3], w[2, 3]}   // glTF RH -> engine LH: negate X, like the vertices
        if mesh_skins[mi] >= 0 {
            pos = skins[mesh_skins[mi]].origin   // placed by its skeleton, not its node
            kit.character = true
        }
        key := mesh_model_keys[mi]
        if key not_in model_pos do model_pos[key] = pos
        if strings.has_suffix(key, COLLISION_SUFFIX) do continue
        append(&kit.nodes, Kit_Node{
            name     = strings.clone(node.name.(string) or_else key[len(file_key) + 1:]),
            model    = key,
            position = pos,
        })
    }
    append(&asset_system.kits, kit)
    asset_import_clips(data, path, file_key, skins)

    for key, pos in model_pos {
        if !strings.has_suffix(key, COLLISION_SUFFIX) do continue
        target := key[:len(key) - len(COLLISION_SUFFIX)]
        target_pos, placed := model_pos[target]
        if !placed do target_pos = pos   // no node of its own model: its vertices are already relative to the same pivot
        asset_cook_collision(asset_intern(target), asset_system.models[key], pos - target_pos)
    }
}

// Authored collision (claude/gameplay.md → Physics): a mesh named <model>_col in the same kit is <model>'s collision
// (an entity's `collision = Collision_Mesh`, the default). Its vertices hold only its node's rotation and scale, like any model's, so
// `offset` moves them from its own pivot to the model's (where the two nodes sit).
COLLISION_SUFFIX :: "_col"

@(private="file")
asset_cook_collision :: proc(target: string, col: Model, offset: vec3) {
    data := asset_cook_mesh(target, col, offset)
    if data == nil do return
    if old, exists := asset_system.collision[target]; exists do b3.DestroyMesh(old)
    asset_system.collision[target] = data
}

// A model's triangles, moved by offset, as Box3D mesh data (nil if it has none or Box3D can't build it). `name`
// is for the log.
@(private="file")
asset_cook_mesh :: proc(name: string, col: Model, offset: vec3) -> ^b3.MeshData {
    verts := make([dynamic]b3.Vec3, context.temp_allocator)
    indices := make([dynamic]i32, context.temp_allocator)
    for mi in col.meshes {
        m := asset_system.meshes[mi]
        base := i32(len(verts))
        for v in 0..<m.vertex_count do append(&verts, asset_system.vertex_positions[m.vertex_offset + v] + offset)
        for t in 0..<m.index_count do append(&indices, base + i32(asset_system.vertex_indices[m.index_offset + t]))
    }
    if len(indices) < 3 do return nil
    // Front faces: cross(v1 - v0, v2 - v0) points out (CLAUDE.md), which is Box3D's CCW rule in its own terms.
    def := b3.MeshDef{
        vertices = raw_data(verts), indices = raw_data(indices),
        vertexCount = c.int(len(verts)), triangleCount = c.int(len(indices) / 3),
        weldVertices = true, weldTolerance = 0.001,
        identifyEdges = true,   // adjacency, so a capsule sliding across a seam doesn't catch on the inner edge
    }
    data := b3.CreateMesh(def, nil, 0)
    if data == nil do log.errorf("Collision for '%v': Box3D couldn't build the mesh", name)
    return data
}

// Smooth normals for a mesh the file gave none: each vertex gets the area-weighted face normals around its
// position, so vertices split for UV seams still shade as one surface. Indices and engine-space positions first.
@(private="file")
mesh_compute_normals :: proc(mesh: Mesh) {
    pos := asset_system.vertex_positions[mesh.vertex_offset:][:mesh.vertex_count]
    idx := asset_system.vertex_indices[mesh.index_offset:][:mesh.index_count]
    face_sum := make([]vec3, len(pos), context.temp_allocator)
    for t := 0; t + 2 < len(idx); t += 3 {
        a, b, c := pos[idx[t]], pos[idx[t + 1]], pos[idx[t + 2]]
        n := la.cross(b - a, c - a)   // front faces: points out (CLAUDE.md), length = twice the area
        for v in idx[t:][:3] do face_sum[v] += n
    }
    // Vertices sorted by position, so each run of equal positions is one point of the surface.
    // (Absolute vertex indices: the comparator can't capture the mesh's offset.)
    order := make([]u32, len(pos), context.temp_allocator)
    for &o, i in order do o = mesh.vertex_offset + u32(i)
    slice.sort_by(order, proc(a, b: u32) -> bool {
        pa, pb := asset_system.vertex_positions[a], asset_system.vertex_positions[b]
        return pa.x != pb.x ? pa.x < pb.x : pa.y != pb.y ? pa.y < pb.y : pa.z < pb.z
    })
    for start := 0; start < len(order); {
        p := asset_system.vertex_positions[order[start]]
        end := start + 1
        for end < len(order) && asset_system.vertex_positions[order[end]] == p do end += 1
        sum: vec3
        for o in order[start:end] do sum += face_sum[o - mesh.vertex_offset]
        for o in order[start:end] do asset_system.vertex_attributes[o].normal = la.normalize0(sum)
        start = end
    }
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

// PNG or JPEG (baseline only: core:image/jpeg rejects progressive files).
asset_system_import_image :: proc(path: string) -> (index: u32, ok: bool) {
    // Decode into scratch, reclaimed on return, and keep only a tightly-owned copy in the asset arena. A large
    // image's decode scratch is several times its size, so the scan can't let it pile up across images.
    temp_mark := vmem.arena_temp_begin(&app.allocators.temp_arena)
    defer vmem.arena_temp_end(temp_mark)
    img, err := image.load(path, {.alpha_add_if_missing}, context.temp_allocator)
    if err != nil {
        log.errorf("Failed to import image, path: %v, err: %v", path, err)
        return 0, false
    }
    defer image.destroy(img)

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
add_decoded_image :: proc(key: string, img: ^image.Image) -> u32 {
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

// Decodes an encoded image (PNG or JPEG) held in memory — a glTF data-URI, an
// external file the loader already read, or a .glb buffer-view blob.
@(private="file")
add_encoded_image :: proc(key: string, encoded: []byte) -> (index: u32, ok: bool) {
    temp_mark := vmem.arena_temp_begin(&app.allocators.temp_arena)   // decode scratch, as in asset_system_import_image
    defer vmem.arena_temp_end(temp_mark)
    img, err := image.load_from_bytes(encoded, {.alpha_add_if_missing}, context.temp_allocator)
    if err != nil {
        log.errorf("Failed to decode embedded image '%v': %v", key, err)
        return 0, false
    }
    defer image.destroy(img)
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
