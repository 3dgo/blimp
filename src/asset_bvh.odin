package blimp

import "core:math/linalg"

// Two levels, one builder. A Mesh_BVH holds one mesh's triangles in object space and is built once
// per mesh at asset load. A Scene_BVH is the top level over a set of mesh instances (entity × mesh,
// world-space bounds) the caller picks; its leaves send the ray into each instance's Mesh_BVH in object space, so
// instancing a mesh costs one leaf, not a copy of its triangles. Both are median-split over
// primitive bounds (bvh_build_nodes).

BVH_LEAF_SIZE :: 4        // triangles per Mesh_BVH leaf
SCENE_BVH_LEAF_SIZE :: 2  // instances per Scene_BVH leaf: each one is a whole mesh walk
BVH_STACK :: 128          // traversal stack: tree depth + 1. Spatial medians can unbalance; a deeper tree trips the bounds check

Triangle :: [3]vec3

BVH_Node :: struct {
    min, max: vec3,
    left, right: i32,
    start, count: u32,   // leaf: its primitives are ids[start:][:count]; count == 0 means interior
}

Mesh_BVH :: struct {
    nodes: []BVH_Node,
    tri_ids: []u32,
    tris: []Triangle,
}

// One entity-mesh pair in a Scene_BVH.
BVH_Instance :: struct {
    to_object: mat4,   // world → mesh space: rays enter the Mesh_BVH through it (t is unchanged: dir isn't renormalized)
    to_world:  mat4,   // the entity transform: hit triangles come back out through it
    mesh:      u32,
    entity:    Entity_Handle,
}

Scene_BVH :: struct {
    nodes:     []BVH_Node,
    inst_ids:  []u32,
    instances: []BVH_Instance,
}

// ============================ Build ============================

bvh_build_for_mesh :: proc(m: Mesh, allocator := context.allocator) -> Mesh_BVH {
    tri_count := int(m.index_count / 3)

    tris := make([]Triangle, tri_count, allocator)
    lo := make([]vec3, tri_count, context.temp_allocator)
    hi := make([]vec3, tri_count, context.temp_allocator)
    for ti in 0..<tri_count {
        i0 := asset_system.vertex_indices[int(m.index_offset) + 3*ti + 0]
        i1 := asset_system.vertex_indices[int(m.index_offset) + 3*ti + 1]
        i2 := asset_system.vertex_indices[int(m.index_offset) + 3*ti + 2]
        t := Triangle{
            asset_system.vertex_positions[m.vertex_offset + i0],
            asset_system.vertex_positions[m.vertex_offset + i1],
            asset_system.vertex_positions[m.vertex_offset + i2],
        }
        tris[ti] = t
        lo[ti] = linalg.min(linalg.min(t[0], t[1]), t[2])
        hi[ti] = linalg.max(linalg.max(t[0], t[1]), t[2])
    }

    nodes, ids := bvh_build_nodes(lo, hi, BVH_LEAF_SIZE, allocator)
    return Mesh_BVH{nodes = nodes, tri_ids = ids, tris = tris}
}

// The top level over `instances` (entity × mesh pairs; to_object is filled in here). A snapshot: nothing
// keeps it in step with later edits, so build it where it's used (the baker builds one per bake, from the
// entities it wants: bake_scene_bvh). Instances whose mesh has no triangles are dropped.
scene_bvh_build :: proc(instances: []BVH_Instance, allocator := context.allocator) -> Scene_BVH {
    kept := make([dynamic]BVH_Instance, 0, len(instances), context.temp_allocator)
    lo := make([dynamic]vec3, 0, len(instances), context.temp_allocator)
    hi := make([dynamic]vec3, 0, len(instances), context.temp_allocator)
    for inst in instances {
        bvh := &asset_system.mesh_bvhs[inst.mesh]
        if len(bvh.nodes) == 0 do continue
        root := bvh.nodes[0]
        wlo, whi := box_transformed_bounds(inst.to_world, root.min, root.max)   // world bounds of the mesh's root box
        append(&kept, BVH_Instance{to_object = linalg.inverse(inst.to_world), to_world = inst.to_world, mesh = inst.mesh, entity = inst.entity})
        append(&lo, wlo)
        append(&hi, whi)
    }

    nodes, ids := bvh_build_nodes(lo[:], hi[:], SCENE_BVH_LEAF_SIZE, allocator)
    sc := Scene_BVH{nodes = nodes, inst_ids = ids, instances = make([]BVH_Instance, len(kept), allocator)}
    copy(sc.instances, kept[:])
    return sc
}

@(private="file")
BVH_Build :: struct {
    lo, hi:    []vec3,   // each primitive's bounds
    centroids: []vec3,
    ids:       []u32,
    nodes:     [dynamic]BVH_Node,
    leaf_size: u32,
}

// Median-split nodes over primitives given by their bounds. Returns the nodes (root first) and the
// primitive ids in leaf order.
@(private="file")
bvh_build_nodes :: proc(lo, hi: []vec3, leaf_size: u32, allocator := context.allocator) -> (nodes: []BVH_Node, ids: []u32) {
    count := len(lo)
    b := BVH_Build {
        lo = lo, hi = hi,
        centroids = make([]vec3, count, context.temp_allocator),
        ids = make([]u32, count, allocator),
        nodes = make([dynamic]BVH_Node, 0, 2*count + 1, context.temp_allocator),
        leaf_size = leaf_size,
    }
    for i in 0..<count {
        b.centroids[i] = 0.5 * (lo[i] + hi[i])
        b.ids[i] = u32(i)
    }
    if count > 0 do bvh_build_node(&b, 0, u32(count))

    nodes = make([]BVH_Node, len(b.nodes), allocator)
    copy(nodes, b.nodes[:])
    return nodes, b.ids
}

@(private="file")
bvh_build_node :: proc(b: ^BVH_Build, first, count: u32) -> i32 {
    my := i32(len(b.nodes))
    append(&b.nodes, BVH_Node{})

    lo := vec3{max(f32), max(f32), max(f32)}
    hi := vec3{min(f32), min(f32), min(f32)}
    for k in first..<first+count {
        lo = linalg.min(lo, b.lo[b.ids[k]])
        hi = linalg.max(hi, b.hi[b.ids[k]])
    }
    b.nodes[my].min = lo
    b.nodes[my].max = hi

    if count <= b.leaf_size {
        b.nodes[my].left = -1; b.nodes[my].right = -1
        b.nodes[my].start = first; b.nodes[my].count = count
        return my
    }

    clo := vec3{max(f32), max(f32), max(f32)}
    chi := vec3{min(f32), min(f32), min(f32)}
    for k in first..<first+count {
        clo = linalg.min(clo, b.centroids[b.ids[k]])
        chi = linalg.max(chi, b.centroids[b.ids[k]])
    }
    ext := chi - clo
    axis := 0
    if ext.y > ext.x do axis = 1
    if ext.z > (axis == 0 ? ext.x : ext.y) do axis = 2
    mid := 0.5 * (clo[axis] + chi[axis])

    i := first
    j := first + count
    for i < j {
        if b.centroids[b.ids[i]][axis] < mid {
            i += 1
        } else {
            j -= 1
            b.ids[i], b.ids[j] = b.ids[j], b.ids[i]
        }
    }
    left_count := i - first
    if left_count == 0 || left_count == count do left_count = count / 2

    l := bvh_build_node(b, first, left_count)
    r := bvh_build_node(b, first + left_count, count - left_count)
    b.nodes[my].left = l; b.nodes[my].right = r
    b.nodes[my].count = 0
    return my
}

// ============================ Queries ============================

BVH_Hit :: struct { t: f32, tri: Triangle, tri_id: u32 }

bvh_closest_hit :: proc(bvh: ^Mesh_BVH, r: Ray) -> (BVH_Hit, bool) {
    t, id, found := mesh_walk(bvh, r, max(f32), false)
    if !found do return {t = max(f32)}, false
    return BVH_Hit{t = t, tri = bvh.tris[id], tri_id = id}, true
}

// A Scene_BVH hit: the instance and its mesh's triangle, so callers can reach the entity, the mesh's
// material and the triangle's world-space vertices (scene_hit_triangle).
Scene_Hit :: struct { t: f32, instance: u32, tri_id: u32 }

scene_bvh_closest_hit :: proc(s: ^Scene_BVH, r: Ray, t_max := max(f32)) -> (Scene_Hit, bool) {
    best := Scene_Hit{t = t_max}
    found := scene_walk(s, r, &best, false)
    return best, found
}

// Anything between the origin and t_max — shadow rays. Stops at the first hit.
scene_bvh_any_hit :: proc(s: ^Scene_BVH, r: Ray, t_max: f32) -> bool {
    best := Scene_Hit{t = t_max}
    return scene_walk(s, r, &best, true)
}

scene_hit_triangle :: proc(s: ^Scene_BVH, hit: Scene_Hit) -> Triangle {
    inst := s.instances[hit.instance]
    t := asset_system.mesh_bvhs[inst.mesh].tris[hit.tri_id]
    return {transform_point(inst.to_world, t[0]), transform_point(inst.to_world, t[1]), transform_point(inst.to_world, t[2])}
}

@(private="file")
scene_walk :: proc(s: ^Scene_BVH, r: Ray, best: ^Scene_Hit, any_hit: bool) -> (found: bool) {
    if len(s.nodes) == 0 do return false
    inv := 1 / r.dir
    stack: [BVH_STACK]i32
    sp := 1   // stack[0] = root
    for sp > 0 {
        sp -= 1
        node := &s.nodes[stack[sp]]
        if !bvh_ray_aabb(r.origin, inv, node.min, node.max, best.t) do continue
        if node.count == 0 {
            stack[sp] = node.left; stack[sp + 1] = node.right; sp += 2
            continue
        }
        for k in node.start ..< node.start + node.count {
            inst_id := s.inst_ids[k]
            inst := &s.instances[inst_id]
            obj := Ray{origin = transform_point(inst.to_object, r.origin), dir = transform_dir(inst.to_object, r.dir)}
            if t, tri, ok := mesh_walk(&asset_system.mesh_bvhs[inst.mesh], obj, best.t, any_hit); ok {
                best^ = {t = t, instance = inst_id, tri_id = tri}
                found = true
                if any_hit do return
            }
        }
    }
    return
}

// The nearest triangle hit closer than t_max (any_hit: the first one found).
@(private="file")
mesh_walk :: proc(bvh: ^Mesh_BVH, r: Ray, t_max: f32, any_hit: bool) -> (t: f32, tri: u32, found: bool) {
    if len(bvh.nodes) == 0 do return
    t = t_max
    inv := 1 / r.dir
    stack: [BVH_STACK]i32
    sp := 1   // stack[0] = root
    for sp > 0 {
        sp -= 1
        node := &bvh.nodes[stack[sp]]
        if !bvh_ray_aabb(r.origin, inv, node.min, node.max, t) do continue
        if node.count == 0 {
            stack[sp] = node.left; stack[sp + 1] = node.right; sp += 2
            continue
        }
        for k in node.start ..< node.start + node.count {
            v := bvh.tris[bvh.tri_ids[k]]
            if tk, ok := ray_triangle(r, v[0], v[1], v[2]); ok && tk < t {
                t = tk; tri = bvh.tri_ids[k]; found = true
                if any_hit do return
            }
        }
    }
    return
}

// Whether the ray enters the box before t_max.
@(private="file")
bvh_ray_aabb :: proc(origin, inv_dir, bmin, bmax: vec3, t_max: f32) -> bool {
    t0 := (bmin - origin) * inv_dir
    t1 := (bmax - origin) * inv_dir
    lo := linalg.min(t0, t1)
    hi := linalg.max(t0, t1)
    tmin := max(lo.x, lo.y, lo.z)
    tmax := min(hi.x, hi.y, hi.z)
    return tmax >= max(tmin, 0) && tmin <= t_max
}
