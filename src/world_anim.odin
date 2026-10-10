package blimp

import "core:log"
import "core:math"
import la "core:math/linalg"
import hm "core:container/handle_map"

// Animation runtime (claude/animation.md): a play world's characters, their clip records and poses.
// Immediate-mode: each tick the world's script samples clips into poses, combines them and outputs one per
// entity; the record of each sampled clip (its time) lives here, keyed by entity and clip, and is dropped the
// first tick nothing samples it. Lua holds no state, so a record is also the answer to "is it attacking".

MAX_ANIMATED     :: 64     // characters per play world
MAX_RECORDS      :: 8      // clips one character samples in a tick
MAX_POSES        :: 256    // poses made in one tick, every character together
MAX_POSE_SOURCES :: 8      // records a pose is made of
MAX_BONES        :: MAX_ANIMATED * MAX_JOINTS   // skin matrices a world uploads per frame (render_buffers.odin)
ANIM_BLEND_TIME  :: 0.2    // seconds a transition takes by default (inertialization)
MASK_FEATHER     :: 2      // joints a layer's mask fades in over, below its root joint
MAX_EVENTS       :: 256    // clip events fired in one tick, every character together
EVENT_WEIGHT     :: 0.5    // a clip fires its events only while it's at least this much of what's shown

Anim_World :: struct {
    characters: [MAX_ANIMATED]Anim_Character,
    slot_of:    [MAX_ENTITIES]u16,   // entity handle index → character slot + 1; 0 = none
    tick:       u64,                 // ticks animated so far: what records are stamped with
    poses:      [MAX_POSES]Pose,     // this tick's; their joints are on the frame arena
    pose_count: int,
    events:      [MAX_EVENTS]Anim_Fired,   // this tick's, for the world script's anim_event hook
    event_count: int,
}

Anim_Fired :: struct {
    entity: Entity_Handle,
    name:   string,   // the clip's (asset memory)
}

Anim_Character :: struct {
    entity:   Entity_Handle,   // zero = free slot
    skeleton: u32,
    records:  [MAX_RECORDS]Anim_Record,
    record_count: int,
    output_tick:  u64,         // the tick it last output a pose
    has_output:   bool,        // prev_out holds a pose (else the next output starts without a transition)
    step:         i64,         // the anim_fps step its skin was last computed in
    half_life:    f32,         // of the running transition's offset decay

    prev_out: [MAX_JOINTS]Joint_Pose,        // last tick's output, what a transition starts from
    offset:   [MAX_JOINTS]Inertial_Offset,   // the transition's remaining difference, decaying to zero
    model:    [MAX_JOINTS]mat4,   // joints in model space (joint queries)
    skin:     [MAX_JOINTS]mat4,   // model × inv_bind: what the vertex shader blends
}

Anim_Record :: struct {
    clip:      u32,
    time:      f32,
    prev_time: f32,     // where this tick's advance started (events fire in (prev_time, time])
    loop:      bool,
    fresh:     bool,    // created (or seeked) this tick: the output inertializes into it
    wrapped:   bool,    // looped past the end this tick
    touched:   u64,     // the tick it was last sampled in
    weight:    f32,     // its share of this tick's output (events fire above EVENT_WEIGHT)
}

Inertial_Offset :: struct { t, t_vel, r, r_vel: vec3 }   // rotation as a scaled axis

// A pose handed to Lua (as one integer, like an entity handle): index + 1, and the tick it was made in, so one
// kept past its tick is refused rather than read stale. Zero = no pose.
@(lua_int="u32") Anim_Pose :: struct {
    index: u16,
    tick:  u16,
}

Pose :: struct {
    character: int,
    joints:    []Joint_Pose,
    sources:   [MAX_POSE_SOURCES]Pose_Source,
    source_count: int,
}

Pose_Source :: struct {
    record: int,
    weight: f32,
}

anim_world_start :: proc(w: ^World) {
    w.anim = new(Anim_World)
}

anim_world_stop :: proc(w: ^World) {
    free(w.anim)
    w.anim = nil
}

// Forgets every character, so nothing refers to clips or skeletons an asset reload threw away.
anim_world_reset :: proc(w: ^World) {
    if w.anim != nil do w.anim^ = {}
}

// The character animating `h`, created if `create` (nil if the entity has no skinned model, or every slot is taken).
anim_character :: proc(w: ^World, h: Entity_Handle, create: bool) -> (^Anim_Character, int) {
    a := w.anim
    if a == nil do return nil, -1
    if s := int(a.slot_of[h.idx]) - 1; s >= 0 && a.characters[s].entity == h do return &a.characters[s], s
    if !create do return nil, -1
    e, ok := hm.get(&w.entities, h)
    if !ok do return nil, -1
    model, has_model := asset_system.models[e.model]
    if !has_model || model.skeleton == NO_SKELETON do return nil, -1
    for &c, s in a.characters do if c.entity == {} {
        c = {entity = h, skeleton = model.skeleton, half_life = ANIM_BLEND_TIME / 2, step = -1}
        a.slot_of[h.idx] = u16(s + 1)
        return &c, s
    }
    log.errorf("More than MAX_ANIMATED (%v) animated entities; '%v' stays in its rest pose", MAX_ANIMATED, sbuf_str(&e.name))
    return nil, -1
}

anim_pose :: proc(w: ^World, p: Anim_Pose) -> ^Pose {
    a := w.anim
    i := int(p.index) - 1
    if a == nil || i < 0 || i >= a.pose_count || p.tick != u16(a.tick) do return nil
    return &a.poses[i]
}

@(private="file")
pose_new :: proc(w: ^World, character: int) -> (Anim_Pose, ^Pose) {
    a := w.anim
    if a.pose_count >= MAX_POSES {
        log.errorf("More than MAX_POSES (%v) poses in one tick", MAX_POSES)
        return {}, nil
    }
    c := &a.characters[character]
    p := &a.poses[a.pose_count]
    p^ = {character = character, joints = make([]Joint_Pose, len(asset_system.skeletons[c.skeleton].parents), app.allocators.frame)}
    a.pose_count += 1
    return {index = u16(a.pose_count), tick = u16(a.tick)}, p
}

@(private="file")
pose_add_sources :: proc(p: ^Pose, from: ^Pose, scale: f32) {
    for s in from.sources[:from.source_count] {
        merged := false
        for &t in p.sources[:p.source_count] do if t.record == s.record {
            t.weight += s.weight * scale
            merged = true
        }
        if !merged && p.source_count < MAX_POSE_SOURCES {
            p.sources[p.source_count] = {s.record, s.weight * scale}
            p.source_count += 1
        }
    }
}

// The record of `clip` on character `c`, advanced to this tick (or created at time 0). Sampling one clip twice
// in a tick on one entity is a script bug: the second gets the same time and logs.
@(private="file")
anim_record :: proc(w: ^World, c: ^Anim_Character, clip_index: u32, speed: f32, loop: bool) -> (int, bool) {
    a := w.anim
    clip := &asset_system.clips[clip_index]
    for &r, i in c.records[:c.record_count] do if r.clip == clip_index {
        if r.touched == a.tick {
            log.errorf("Clip '%v' sampled twice in one tick on one entity", clip.name)
            return i, true
        }
        r.touched, r.loop = a.tick, loop
        r.prev_time = r.time
        r.time += w.dt * speed
        r.wrapped = false
        if loop && clip.duration > 0 {
            if r.time >= clip.duration do r.wrapped = true
            r.time = math.mod(r.time, clip.duration)
            if r.time < 0 do r.time += clip.duration
        } else {
            r.time = clamp(r.time, 0, clip.duration)
        }
        if speed < 0 do r.prev_time = r.time   // played backwards: no events
        return i, true
    }
    if c.record_count >= MAX_RECORDS {
        log.errorf("More than MAX_RECORDS (%v) clips sampled on one entity in a tick", MAX_RECORDS)
        return 0, false
    }
    c.records[c.record_count] = {clip = clip_index, loop = loop, fresh = true, touched = a.tick, prev_time = -1}   // -1: an event at 0 fires
    c.record_count += 1
    return c.record_count - 1, true
}

// ---------------------------------------------------------------------------------------------------------------
// Pose ops. Each makes a new pose for this tick; 0 means it failed (logged), and every op passes a 0 through.

// Samples `clip_name` (a clip of the entity's skeleton) at its record's time, advanced by dt × speed.
anim_sample :: proc(w: ^World, h: Entity_Handle, clip_name: string, speed: f32 = 1, loop := true) -> Anim_Pose {
    c, ci := anim_character(w, h, true)
    if c == nil do return {}
    skel := &asset_system.skeletons[c.skeleton]
    clip_index, found := skel.clips[clip_name]
    if !found {
        log.errorf("No clip '%v' on skeleton '%v'", clip_name, skel.key)
        return {}
    }
    ri, ok := anim_record(w, c, clip_index, speed, loop)
    if !ok do return {}
    handle, p := pose_new(w, ci)
    if p == nil do return {}
    clip_sample(&asset_system.clips[clip_index], c.records[ri].time, p.joints)
    p.sources[0] = {ri, 1}
    p.source_count = 1
    return handle
}

// a → b by `weight` (0 = a, 1 = b), joint by joint.
anim_blend :: proc(w: ^World, pa, pb: Anim_Pose, weight: f32) -> Anim_Pose {
    a, b := anim_pose(w, pa), anim_pose(w, pb)
    if a == nil || b == nil || a.character != b.character do return {}
    t := clamp(weight, 0, 1)
    handle, p := pose_new(w, a.character)
    if p == nil do return {}
    for &j, i in p.joints {
        j = {t = la.lerp(a.joints[i].t, b.joints[i].t, t), r = quat_nlerp(a.joints[i].r, b.joints[i].r, t), s = la.lerp(a.joints[i].s, b.joints[i].s, t)}
    }
    pose_add_sources(p, a, 1 - t)
    pose_add_sources(p, b, t)
    return handle
}

// `over` on top of `base` for the joint named `joint` and everything below it, by `weight`. The mask fades in
// over MASK_FEATHER joints below its root, so the seam doesn't show.
anim_layer :: proc(w: ^World, pbase, pover: Anim_Pose, joint: string, weight: f32) -> Anim_Pose {
    base, over := anim_pose(w, pbase), anim_pose(w, pover)
    if base == nil || over == nil || base.character != over.character do return {}
    skel := &asset_system.skeletons[w.anim.characters[base.character].skeleton]
    root := -1
    for name, i in skel.names do if name == joint { root = i; break }
    if root < 0 {
        log.errorf("No joint '%v' on skeleton '%v'", joint, skel.key)
        return {}
    }
    handle, p := pose_new(w, base.character)
    if p == nil do return {}
    // Depth below the mask's root, parents first: -1 = outside the mask.
    depth := make([]int, len(skel.parents), context.temp_allocator)
    for parent, i in skel.parents {
        depth[i] = -1
        if i == root {
            depth[i] = 0
        } else if parent != NO_JOINT && depth[parent] >= 0 {
            depth[i] = depth[parent] + 1
        }
    }
    t := clamp(weight, 0, 1)
    for &j, i in p.joints {
        k := depth[i] < 0 ? 0 : t * min(1, f32(depth[i] + 1) / f32(MASK_FEATHER + 1))
        a, b := base.joints[i], over.joints[i]
        j = {t = la.lerp(a.t, b.t, k), r = quat_nlerp(a.r, b.r, k), s = la.lerp(a.s, b.s, k)}
    }
    pose_add_sources(p, base, 1)
    pose_add_sources(p, over, t)
    return handle
}

// Makes `pose` the entity's pose this tick. A clip that started this tick (or was seeked) starts a transition
// from what was shown, over about blend_time: the difference decays to zero (inertialization), so a switch
// needs no fade weights. Joint queries after this are this tick's.
anim_output :: proc(w: ^World, h: Entity_Handle, pose: Anim_Pose, blend_time: f32 = ANIM_BLEND_TIME) {
    p := anim_pose(w, pose)
    c, ci := anim_character(w, h, false)
    if p == nil || c == nil || p.character != ci do return
    a := w.anim
    if c.output_tick == a.tick && c.has_output {
        log.errorf("Entity output two poses in one tick; the first is kept")
        return
    }
    n := len(p.joints)

    transition := false
    for s in p.sources[:p.source_count] do if c.records[s.record].fresh do transition = true
    // The new offset is what was shown minus the new source. It starts at rest: the new clip's own velocity isn't
    // known, and guessing zero would add motion neither clip has.
    if transition && c.has_output {
        c.half_life = max(blend_time, 0.001) / 2
        for i in 0..<n {
            src := p.joints[i]
            c.offset[i] = {t = c.prev_out[i].t - src.t, r = quat_to_scaled_axis(quat_shortest(c.prev_out[i].r * la.quaternion_inverse(src.r)))}
        }
    }
    for s in p.sources[:p.source_count] do c.records[s.record].weight += s.weight

    // Decay the offset (a critically damped spring at rest at zero) and add it on.
    y := 2 * math.LN2 / c.half_life
    decay := math.exp(-y * w.dt)
    dt := w.dt
    for i in 0..<n {
        o := &c.offset[i]
        jt := o.t_vel + o.t * y
        o.t, o.t_vel = decay * (o.t + jt * dt), decay * (o.t_vel - jt * y * dt)
        jr := o.r_vel + o.r * y
        o.r, o.r_vel = decay * (o.r + jr * dt), decay * (o.r_vel - jr * y * dt)

        src := p.joints[i]
        c.prev_out[i] = {t = src.t + o.t, r = la.normalize(quat_from_scaled_axis(o.r) * src.r), s = src.s}
    }
    c.has_output = true
    c.output_tick = a.tick

    // Stepped motion (World_Settings.anim_fps): the shown pose only moves on whole steps. Time, events and the
    // transitions above stay continuous.
    step := i64(-2)
    if w.settings.anim_fps > 0 do step = i64(math.floor(w.game.time * f64(w.settings.anim_fps)))
    if step != c.step || step == -2 {
        c.step = step
        skel := &asset_system.skeletons[c.skeleton]
        skeleton_model_matrices(skel, c.prev_out[:n], c.model[:n])
        for i in 0..<n do c.skin[i] = c.model[i] * skel.inv_bind[i]
    }
}

// Puts the record of `clip_name` at `time`, firing nothing on the way, and starts a transition into it.
anim_seek :: proc(w: ^World, h: Entity_Handle, clip_name: string, time: f32) {
    c, _ := anim_character(w, h, false)
    if c == nil do return
    clip_index, found := asset_system.skeletons[c.skeleton].clips[clip_name]
    if !found do return
    for &r in c.records[:c.record_count] do if r.clip == clip_index {
        r.time = clamp(time, 0, asset_system.clips[clip_index].duration)
        r.prev_time, r.fresh, r.wrapped = r.time, true, false   // sampled after this, it advances from here
    }
}

// The record of `clip_name` on the entity: alive since the last tick (sampled then or this tick).
anim_find_record :: proc(w: ^World, h: Entity_Handle, clip_name: string) -> (^Anim_Record, ^Clip) {
    c, _ := anim_character(w, h, false)
    if c == nil do return nil, nil
    clip_index, found := asset_system.skeletons[c.skeleton].clips[clip_name]
    if !found do return nil, nil
    for &r in c.records[:c.record_count] do if r.clip == clip_index do return &r, &asset_system.clips[clip_index]
    return nil, nil
}

// The clip is being played: sampled last tick or this one, and looping or not at its end.
anim_playing :: proc(w: ^World, h: Entity_Handle, clip_name: string) -> bool {
    r, clip := anim_find_record(w, h, clip_name)
    return r != nil && (r.loop || r.time < clip.duration)
}

// World position and rotation of a joint, as of the entity's last output.
anim_joint :: proc(w: ^World, h: Entity_Handle, joint: string) -> (pos: vec3, rot: quat, ok: bool) {
    rot = 1
    c, _ := anim_character(w, h, false)
    e, has_e := hm.get(&w.entities, h)
    if c == nil || !has_e do return
    skel := &asset_system.skeletons[c.skeleton]
    for name, i in skel.names do if name == joint {
        m := entity_transform(e) * c.model[i]
        pos = mat_translation(m)
        basis := la.matrix3_from_matrix4_f32(m)
        for col in 0..<3 {
            v := vec3{basis[0, col], basis[1, col], basis[2, col]}
            v = la.normalize0(v)
            basis[0, col], basis[1, col], basis[2, col] = v.x, v.y, v.z
        }
        return pos, la.quaternion_from_matrix3_f32(basis), true
    }
    return
}

// After the world's script, on ticking frames: entities with an `anim` clip that their script gave no pose
// loop it; characters nobody animated this tick go back to the rest pose (unskinned); records not sampled this
// tick are dropped.
anim_update :: proc(w: ^World) {
    a := w.anim
    if a == nil || !w.ticks do return
    a.event_count = 0

    it := hm.iterator_make(&w.entities)
    for e, h in hm.iterate(&it) {
        clip := sbuf_str(&e.anim)
        if clip == "" || !entity_enabled(e) do continue
        if c, _ := anim_character(w, h, false); c != nil && c.output_tick == a.tick && c.has_output do continue
        model, has_model := asset_system.models[e.model]
        if !has_model || model.skeleton == NO_SKELETON do continue
        if clip not_in asset_system.skeletons[model.skeleton].clips do continue   // a typo shows as the rest pose
        anim_output(w, h, anim_sample(w, h, clip))
    }

    for &c in a.characters {
        if c.entity == {} do continue
        if _, alive := hm.get(&w.entities, c.entity); !alive || c.output_tick != a.tick || !c.has_output {
            a.slot_of[c.entity.idx] = 0
            c = {}
            continue
        }
        for r in c.records[:c.record_count] do if r.touched == a.tick && r.weight >= EVENT_WEIGHT {
            anim_fire_events(a, c.entity, r)
        }
        kept := 0
        for r in c.records[:c.record_count] do if r.touched == a.tick {
            c.records[kept] = r
            c.records[kept].fresh, c.records[kept].weight = false, 0
            kept += 1
        }
        c.record_count = kept
    }
    a.tick += 1
    a.pose_count = 0
}

// The clip's events this tick's advance passed: (prev_time, time], in two parts when it looped round.
@(private="file")
anim_fire_events :: proc(a: ^Anim_World, entity: Entity_Handle, r: Anim_Record) {
    clip := &asset_system.clips[r.clip]
    fire :: proc(a: ^Anim_World, entity: Entity_Handle, clip: ^Clip, from, to: f32) {
        for ev in clip.events do if ev.time > from && ev.time <= to {
            if a.event_count >= MAX_EVENTS {
                log.errorf("More than MAX_EVENTS (%v) clip events in one tick", MAX_EVENTS)
                return
            }
            a.events[a.event_count] = {entity, ev.name}
            a.event_count += 1
        }
    }
    if r.wrapped {
        fire(a, entity, clip, r.prev_time, clip.duration)
        fire(a, entity, clip, -1, r.time)
    } else {
        fire(a, entity, clip, r.prev_time, r.time)
    }
}

// This tick's clip events (after anim_update), for the world script.
anim_events :: proc(w: ^World) -> []Anim_Fired {
    if w.anim == nil || !w.ticks do return nil
    return w.anim.events[:w.anim.event_count]
}

// The entity's skin matrices this frame, if it's animated (render_buffers.odin): none = draw its rest pose.
anim_skin :: proc(w: ^World, h: Entity_Handle) -> []mat4 {
    c, _ := anim_character(w, h, false)
    if c == nil || !c.has_output do return nil
    return c.skin[:len(asset_system.skeletons[c.skeleton].parents)]
}

@(private="file")
quat_shortest :: proc(q: quat) -> quat {
    return q.w < 0 ? -q : q
}

@(private="file")
quat_to_scaled_axis :: proc(q: quat) -> vec3 {
    v := vec3{q.x, q.y, q.z}
    s := la.length(v)
    if s < 1e-6 do return 2 * v
    return v * (2 * math.atan2(s, q.w) / s)
}

@(private="file")
quat_from_scaled_axis :: proc(v: vec3) -> quat {
    angle := la.length(v)
    if angle < 1e-6 do return la.normalize(quaternion(w = 1, x = v.x / 2, y = v.y / 2, z = v.z / 2))
    return la.quaternion_angle_axis_f32(angle, v / angle)
}
