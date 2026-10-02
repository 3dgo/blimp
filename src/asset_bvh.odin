package blimp

BVH_LEAF_SIZE :: 4

Triangle :: [3]vec3

BVH_Node :: struct {
    min, max: vec3,
    left, right: i32,
    start, count: u32,
}

Mesh_BVH :: struct {
    nodes: []BVH_Node,
    tri_ids: []u32,
    tris: []Triangle,
}

@(private="file")
BVH_Build :: struct {
    tris: []Triangle,
    centroids: []vec3,
    tri_ids: []u32,
    nodes: [dynamic]BVH_Node,
}

bvh_build_for_mesh :: proc(m: Mesh, allocator := context.allocator) -> Mesh_BVH {
    tri_count := int(m.index_count / 3)

    tris := make([]Triangle, tri_count, allocator)
    for ti in 0..<tri_count {
        i0 := asset_system.vertex_indices[int(m.index_offset) + 3*ti + 0]
        i1 := asset_system.vertex_indices[int(m.index_offset) + 3*ti + 1]
        i2 := asset_system.vertex_indices[int(m.index_offset) + 3*ti + 2]
        tris[ti] = {
            asset_system.vertex_positions[m.vertex_offset + i0],
            asset_system.vertex_positions[m.vertex_offset + i1],
            asset_system.vertex_positions[m.vertex_offset + i2],
        }
    }

    b := BVH_Build {
        tris = tris,
        centroids = make([]vec3, tri_count, context.temp_allocator),
        tri_ids = make([]u32, tri_count, context.temp_allocator),
        nodes = make([dynamic]BVH_Node, 0, 2*tri_count + 1, context.temp_allocator),
    }
    for ti in 0..<tri_count {
        t := tris[ti]
        b.centroids[ti] = (t[0] + t[1] + t[2]) / 3
        b.tri_ids[ti] = u32(ti)
    }

    if tri_count > 0 do bvh_build_node(&b, 0, u32(tri_count))

    bvh := Mesh_BVH {
        nodes = make([]BVH_Node, len(b.nodes), allocator),
        tri_ids = make([]u32, tri_count, allocator),
        tris = tris,
    }
    copy(bvh.nodes, b.nodes[:])
    copy(bvh.tri_ids, b.tri_ids)
    return bvh
}

@(private="file")
bvh_build_node :: proc(b: ^BVH_Build, first, count: u32) -> i32 {
    my := i32(len(b.nodes))
    append(&b.nodes, BVH_Node{})

    lo := vec3{max(f32), max(f32), max(f32)}
    hi := vec3{min(f32), min(f32), min(f32)}

    for k in first..<first+count {
        t := b.tris[b.tri_ids[k]]
        for ci in 0..<3 {
            p := t[ci]
            lo = {min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)}
            hi = {max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)}
        }
    }
    b.nodes[my].min = lo
    b.nodes[my].max = hi

    if count <= BVH_LEAF_SIZE {
        b.nodes[my].left = -1; b.nodes[my].right = -1
        b.nodes[my].start = first; b.nodes[my].count = count
        return my
    }

    clo := vec3{max(f32), max(f32), max(f32)}
    chi := vec3{min(f32), min(f32), min(f32)}
    for k in first..<first+count {
        c := b.centroids[b.tri_ids[k]]
        clo = {min(clo.x,c.x), min(clo.y,c.y), min(clo.z,c.z)}
        chi = {max(chi.x,c.x), max(chi.y,c.y), max(chi.z,c.z)}
    }
    ext := chi - clo
    axis := 0
    if ext.y > ext.x do axis = 1
    if ext.z > (axis == 0 ? ext.x : ext.y) do axis = 2
    mid := 0.5 * (clo[axis] + chi[axis])

    i := first
    j := first + count
    for i < j {
        if b.centroids[b.tri_ids[i]][axis] < mid {
            i += 1
        } else {
            j -= 1
            b.tri_ids[i], b.tri_ids[j] = b.tri_ids[j], b.tri_ids[i]
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


BVH_Hit :: struct { t: f32, tri: Triangle }

bvh_closest_hit :: proc(bvh: ^Mesh_BVH, r: Ray) -> (BVH_Hit, bool) {
    best := BVH_Hit{ t = max(f32) }
    found := false
    if len(bvh.nodes) > 0 do bvh_walk(bvh, r, 0, &best, &found)
    return best, found
}

@(private="file")
bvh_walk :: proc(bvh: ^Mesh_BVH, r: Ray, node_idx: i32, best: ^BVH_Hit, found: ^bool) {
    node := bvh.nodes[node_idx]
    tmin, hit := bvh_ray_aabb(r, node.min, node.max)
    if !hit || tmin > best.t do return

    if node.count > 0 {
        for k in node.start ..< node.start + node.count {
            tri := bvh.tris[bvh.tri_ids[k]]
            if t, ok := ray_triangle(r, tri[0], tri[1], tri[2]); ok && t < best.t {
                best.t = t; best.tri = tri; found^ = true
            }
        }
        return
    }
    bvh_walk(bvh, r, node.left, best, found)
    bvh_walk(bvh, r, node.right, best, found)
}

@(private="file")
bvh_ray_aabb :: proc(r: Ray, bmin, bmax: vec3) -> (tmin: f32, hit: bool) {
    inv := vec3{ 1.0/r.dir.x, 1.0/r.dir.y, 1.0/r.dir.z}
    t0 := (bmin - r.origin) * inv
    t1 := (bmax - r.origin) * inv
    lo := vec3{min(t0.x, t1.x), min(t0.y, t1.y), min(t0.z, t1.z)}
    hi := vec3{max(t0.x, t1.x), max(t0.y, t1.y), max(t0.z, t1.z)}
    tmin = max(lo.x, lo.y, lo.z)
    tmax := min(hi.x, hi.y, hi.z)
    hit = tmax >= max(tmin, 0)
    return
}