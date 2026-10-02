package blimp

import "core:c"
import "core:log"
import "core:math/linalg"
import hm "core:container/handle_map"
import b3 "vendor:box3d"

// Collision (claude/gameplay.md → Physics — Box3D). Queries only so far: nothing is simulated, there are no
// dynamic bodies, and Box3D's world is never stepped.
//
// A play world gets a Box3D world when Play starts, with a body for every enabled entity whose `collision` gives it
// a shape (physics_entity_shape), cheapest first: None, Box = the model's bounds, Collision_Mesh = the kit's
// <model>_col mesh (authored; Play warns about models that have none), Render_Mesh = the model's own triangles. Static entities are static bodies. Anything else is
// kinematic and follows its entity every frame (physics_update), so a drawbridge a script swings still blocks; its
// scale is the one it had at Play. It's all freed on Stop, and an asset reload rebuilds it. Entities spawned
// during play don't collide yet.
//
// Lua asks it things and moves characters through it; the answer is Odin's, so Lua holds nothing:
//   World.raycast(origin, direction, distance) → hit, point, normal, entity
//   Entity.move(e, delta, radius, height)      → grounded   (a capsule standing on e's position, sliding; never
//                                                             stopped by e's own collision)
// Box3D has no handedness of its own: it gets the engine's left-handed coordinates as they are.

Physics_World :: struct {
    id:      b3.WorldId,
    bodies:  int,                        // bodies made at Play, for the log
    follows: [dynamic]Physics_Follow,    // the kinematic ones (app.allocators.perm)
}

// A kinematic body and the entity it follows, with the transform it was last given.
Physics_Follow :: struct {
    entity:   Entity_Handle,
    body:     b3.BodyId,
    position: vec3,
    rotation: quat,
}

// Box3D's asserts are compiled in (its lib is built without NDEBUG). Its own handler printf's (lost when the
// process dies) and breaks; this one logs first, then breaks into the debugger the same way.
@(private="file")
physics_assert :: proc "c" (condition, file: cstring, line: c.int) -> c.int {
    context = app.g_context
    log.errorf("Box3D assert: %s (%s:%v)", condition, file, line)
    return 1
}

// Box3D world for a play world, from its entities as Play starts.
physics_world_start :: proc(w: ^World) {
    b3.SetAssertFcn(physics_assert)
    def := b3.DefaultWorldDef()
    def.gravity = {0, -9.8, 0}
    w.physics.id = b3.CreateWorld(def)
    w.physics.follows = make([dynamic]Physics_Follow, app.allocators.perm)

    shape_def := b3.DefaultShapeDef()
    missing_col: int     // entities asking for a _col mesh their model doesn't have
    missing_example: string
    it := hm.iterator_make(&w.entities)
    for e, h in hm.iterate(&it) {
        if .Enabled not_in e.basic_flags do continue
        shape, has := physics_entity_shape(e)
        if !has {
            if e.collision == .Collision_Mesh && e.model != "" {
                if missing_col == 0 do missing_example = sbuf_str(&e.name)
                missing_col += 1
            }
            continue
        }
        moving := .Static not_in e.basic_static_flags
        body_def := b3.DefaultBodyDef()
        body_def.type = moving ? .kinematicBody : .staticBody
        body_def.position = e.position
        body_def.rotation = linalg.normalize(e.rotation)   // Box3D asserts unit length tighter than a level file's 5 decimals
        body := b3.CreateBody(w.physics.id, body_def)
        shape_def.userData = rawptr(uintptr(transmute(u32)h))   // the entity a hit belongs to
        switch &s in shape {
        case ^b3.MeshData: _ = b3.CreateMeshShape(body, shape_def, s, e.scale)
        case b3.BoxHull:   _ = b3.CreateHullShape(body, shape_def, &s.base)
        }
        if moving do append(&w.physics.follows, Physics_Follow{entity = h, body = body, position = e.position, rotation = e.rotation})
        w.physics.bodies += 1
    }
    log.infof("Physics '%v': %v bodies, %v of them following moving entities", w.title, w.physics.bodies, len(w.physics.follows))
    if missing_col > 0 {
        log.warnf("Physics '%v': %v entities (e.g. '%v') want a Collision Mesh their model has no %v mesh for; they don't collide. Author one in the kit, or set their Collision to Box, Render Mesh or None",
            w.title, missing_col, missing_example, COLLISION_SUFFIX)
    }
}

// What entity e collides as: a mesh (Collision_Mesh, Render_Mesh; scaled by the body) or a box hull (Box, already scaled).
Physics_Shape :: union {
    ^b3.MeshData,
    b3.BoxHull,
}

physics_entity_shape :: proc(e: ^Entity) -> (shape: Physics_Shape, ok: bool) {
    if e.model == "" do return
    switch e.collision {
    case .None:
        return
    case .Collision_Mesh:
        m := asset_system.collision[e.model] or_return
        return m, true
    case .Render_Mesh:
        m := asset_render_collision(e.model)
        return m, m != nil
    case .Box:
        model := asset_system.models[e.model] or_return
        lo, hi := model_bounds(model)
        half := linalg.max((hi - lo) * 0.5 * linalg.abs(e.scale), vec3(0.005))   // a flat model still gets a thin slab
        centre := (lo + hi) * 0.5 * e.scale
        return b3.MakeOffsetBoxHull(half.x, half.y, half.z, centre), true
    }
    return
}

physics_world_stop :: proc(w: ^World) {
    if b3.IS_NULL(w.physics.id) do return
    b3.DestroyWorld(w.physics.id)
    delete(w.physics.follows)
    w.physics = {}
}

// Once a frame, after the game systems moved things: kinematic bodies take their entity's transform. One whose
// entity is gone is destroyed.
physics_update :: proc() {
    for w in worlds {
        if b3.IS_NULL(w.physics.id) do continue
        for i := 0; i < len(w.physics.follows); {
            f := &w.physics.follows[i]
            e, ok := entity_get(w, f.entity)
            if !ok {
                b3.DestroyBody(f.body)
                unordered_remove(&w.physics.follows, i)
                continue
            }
            if e.position != f.position || e.rotation != f.rotation {
                b3.Body_SetTransform(f.body, e.position, linalg.normalize(e.rotation))
                f.position, f.rotation = e.position, e.rotation
            }
            i += 1
        }
    }
}

// Every play world's, around an asset reload (asset_system_reload): their shapes use the collision data.
physics_worlds_stop :: proc() {
    for w in worlds do if w.play_source != nil do physics_world_stop(w)
}

physics_worlds_start :: proc() {
    for w in worlds do if w.play_source != nil do physics_world_start(w)
}

// ============================ Queries ============================

Physics_Hit :: struct {
    point, normal: vec3,
    entity:        Entity_Handle,
    distance:      f32,
}

// The first collision along the ray from origin in `direction` (normalized here), up to `distance` away.
physics_raycast :: proc(w: ^World, origin, direction: vec3, distance: f32) -> (hit: Physics_Hit, ok: bool) {
    if b3.IS_NULL(w.physics.id) || distance <= 0 do return
    dir := linalg.normalize0(direction)
    if dir == {} do return
    r := b3.World_CastRayClosest(w.physics.id, origin, dir * distance, b3.DefaultQueryFilter())
    if !r.hit do return
    return {point = r.point, normal = r.normal, entity = physics_shape_entity(r.shapeId), distance = r.fraction * distance}, true
}

MOVER_ITERATIONS :: 5
MOVER_MAX_PLANES :: 16
MOVER_TOLERANCE  :: 0.001   // metres: an iteration that moves less than this ends the solve
GROUND_MIN_UP    :: 0.7     // a plane this far toward +Y (cos ≈ 45°) is ground to stand on

// Moves a capsule standing on `position` (radius, total height) by `delta`, sliding along collision instead of
// passing through it: Box3D's character mover (collide → solve planes → cast, a few times over). Returns where it
// ended, and whether it's standing on ground (touching a plane that faces up). `self`'s own collision, if it has
// any, never stops it.
physics_move_capsule :: proc(w: ^World, position, delta: vec3, capsule_radius, height: f32, self: Entity_Handle = {}) -> (end: vec3, grounded: bool) {
    if b3.IS_NULL(w.physics.id) do return position + delta, false
    radius := max(capsule_radius, 0.01)
    capsule := b3.Capsule{center1 = {0, radius, 0}, center2 = {0, max(height - radius, radius), 0}, radius = radius}
    filter := b3.DefaultQueryFilter()

    Planes :: struct {
        planes: [MOVER_MAX_PLANES]b3.CollisionPlane,
        count:  int,
        self:   rawptr,   // the moving entity's shape user data; nil = nothing to skip
    }
    gather :: proc "c" (shape: b3.ShapeId, results: [^]b3.PlaneResult, count: c.int, ctx: rawptr) -> bool {
        p := (^Planes)(ctx)
        if p.self != nil && b3.Shape_GetUserData(shape) == p.self do return true
        for i in 0..<int(count) {
            if p.count == MOVER_MAX_PLANES do return false
            p.planes[p.count] = {plane = results[i].plane, pushLimit = max(f32), clipVelocity = true}
            p.count += 1
        }
        return true
    }
    not_self :: proc "c" (shape: b3.ShapeId, ctx: rawptr) -> bool {
        p := (^Planes)(ctx)
        return p.self == nil || b3.Shape_GetUserData(shape) != p.self
    }

    pos := position
    target := position + delta
    planes: Planes
    if self != {} do planes.self = rawptr(uintptr(transmute(u32)self))
    for _ in 0..<MOVER_ITERATIONS {
        planes.count = 0
        b3.World_CollideMover(w.physics.id, pos, capsule, filter, gather, &planes)
        solved := b3.SolvePlanes(target - pos, &planes.planes[0], c.int(planes.count))
        fraction := b3.World_CastMover(w.physics.id, pos, capsule, solved.delta, filter, not_self, &planes)
        step := solved.delta * fraction
        pos += step
        if linalg.length2(step) < MOVER_TOLERANCE * MOVER_TOLERANCE do break
    }
    for p in planes.planes[:planes.count] do if p.plane.normal.y >= GROUND_MIN_UP do grounded = true
    return pos, grounded
}

@(private="file")
physics_shape_entity :: proc(shape: b3.ShapeId) -> Entity_Handle {
    return transmute(Entity_Handle)u32(uintptr(b3.Shape_GetUserData(shape)))
}

// ============================ Lua ============================

// The first static collision along the ray (direction needn't be unit length), up to `distance`: whether it hit,
// where, the surface normal there, and the entity it belongs to.
@(lua=raycast, table=World, lua_zh="射线检测")
world_raycast_lua :: proc(origin: vec3, direction: vec3, distance: f32) -> (bool, vec3, vec3, Entity_Handle) {
    hit, ok := physics_raycast(lua_world(), origin, direction, distance)
    return ok, hit.point, hit.normal, hit.entity
}

// Moves the entity by `delta` as a capsule of `radius` and total `height` standing on its position, sliding along
// static collision (walls stop it, slopes and steps it rides). True if it ends standing on ground. Gravity is
// part of delta: Lua decides how things fall.
@(lua=move, table=Entity, lua_zh="移动")
entity_move_lua :: proc(handle: Entity_Handle, delta: vec3, radius: f32, height: f32) -> bool {
    w := lua_world()
    e, ok := entity_get(w, handle)
    if !ok do return false
    end, grounded := physics_move_capsule(w, e.position, delta, radius, height, handle)
    e.position = end
    return grounded
}
