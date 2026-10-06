package blimp

import "core:fmt"
import "core:log"
import "core:math"
import la "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "lib:gltf2"

// Skeletal animation assets (claude/animation.md → Assets): a skeleton per glTF skin, clips baked at
// import. Everything here is engine space (left-handed, the glTF's -X reflection applied) unless a name
// says glTF.

MAX_JOINTS  :: 128         // per skeleton; joint indices are u8 (Skin_Vertex)
NO_JOINT    :: u8(0xFF)    // a top joint's parent
NO_SKELETON :: max(u32)    // Model.skeleton of an unskinned model
NO_SKIN     :: max(u32)    // Mesh.skin_offset of an unskinned mesh
CLIP_RATE   :: 30          // Hz: clips are resampled to about this at import, so sampling is two frames and a lerp

// One joint's local transform. Poses are arrays of these, one per skeleton joint, in skeleton order.
Joint_Pose :: struct {
    t: vec3,
    r: quat,
    s: vec3,
}

Skeleton :: struct {
    key:         string,           // file:skin name
    parents:     []u8,             // parent before child; NO_JOINT for a top joint
    names:       []string,         // glTF node names, for masks and joint queries
    rest:        []Joint_Pose,     // the pose the file shows, local
    inv_bind:    []mat4,           // the rest pose's model matrices inverted: skin = model × inv_bind
    root_parent: mat4,             // rotation/scale above the top joints (a DCC's Z-up node, unit scale)
    clips:       map[string]u32,   // short clip name → asset_system.clips index
}

Clip :: struct {
    key:         string,          // file:animation name
    name:        string,          // the short name scripts and the `anim` field use
    skeleton:    u32,
    duration:    f32,             // seconds
    frame_count: u32,             // ≥ 2, evenly spread over [0, duration]
    poses:       []Joint_Pose,    // frame-major: frame f is poses[f * joint_count:][:joint_count]
    root_speed:  f32,             // model units per second the clip travelled before it was made in place
    events:      []Anim_Event,    // by time, from the kit's .clips file
}

// A named moment in a clip (a footstep), fired to the world script as it's played past (world_anim.odin).
Anim_Event :: struct {
    time: f32,
    name: string,
}

// Per vertex of a skinned mesh, parallel to its positions from Mesh.skin_offset. Weights are unorm8
// summing to 255.
Skin_Vertex :: struct {
    joints:  [4]u8,
    weights: [4]u8,
}

// What a glTF skin became, for the mesh and clip import that follow (temp, one glTF's import).
Gltf_Skin :: struct {
    skeleton:   u32,
    slot_joint: []u8,     // glTF skin.joints slot → skeleton joint
    node_joint: map[int]u8,   // glTF node → skeleton joint
    bind:       []mat4,   // per slot: glTF vertex → rest pose in model space (glTF handedness)
    origin:     vec3,     // where the skeleton's parent sits: the kit node position
}

// glTF ↔ engine handedness: x → -x (claude/assets.md). S·M·S for a matrix.
@(private="file")
REFLECT :: mat4{-1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  0, 0, 0, 1}

@(private="file")
pose_reflect :: proc(p: Joint_Pose) -> Joint_Pose {
    return {t = {-p.t.x, p.t.y, p.t.z}, r = quaternion(w = p.r.w, x = p.r.x, y = -p.r.y, z = -p.r.z), s = p.s}
}

mat_translation :: proc(m: mat4) -> vec3 { return {m[0, 3], m[1, 3], m[2, 3]} }

joint_matrix :: proc(p: Joint_Pose) -> mat4 {
    return la.matrix4_from_trs_f32(p.t, p.r, p.s)
}

// Model-space matrix of every joint of `pose`, parents first.
skeleton_model_matrices :: proc(skel: ^Skeleton, pose: []Joint_Pose, out: []mat4) {
    for p, j in skel.parents {
        parent := p == NO_JOINT ? skel.root_parent : out[p]
        out[j] = parent * joint_matrix(pose[j])
    }
}

// nlerp along the shorter arc.
quat_nlerp :: proc(a, b: quat, t: f32) -> quat {
    b := b
    if a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w < 0 do b = -b
    return la.quaternion_nlerp_f32(a, b, t)
}

// One frame of a clip, sampled at `time` (clamped to the clip). Writes every joint of `out`.
clip_sample :: proc(clip: ^Clip, time: f32, out: []Joint_Pose) {
    n := len(out)
    f := clip.duration > 0 ? clamp(time / clip.duration, 0, 1) * f32(clip.frame_count - 1) : 0
    i := min(u32(f), clip.frame_count - 2)
    k := f - f32(i)
    a := clip.poses[int(i) * n:][:n]
    b := clip.poses[int(i + 1) * n:][:n]
    for j in 0..<n {
        out[j] = {t = la.lerp(a[j].t, b[j].t, k), r = quat_nlerp(a[j].r, b[j].r, k), s = la.lerp(a[j].s, b[j].s, k)}
    }
}

// The gltf2 lib refuses any accessor whose buffer view declares a byteStride, and exporters (Blender's,
// the Khronos samples) write one even for tightly packed data. Drops strides that equal the element size of
// every accessor reading the view; false (and logs) when one is really interleaved.
gltf_drop_packed_strides :: proc(data: ^gltf2.Data, path: string) -> bool {
    for a in data.accessors {
        view, has_view := a.buffer_view.?
        if !has_view do continue
        stride, has_stride := data.buffer_views[view].byte_stride.?
        if !has_stride do continue
        if stride != gltf_element_size(a) {
            log.errorf("Interleaved vertex data isn't supported (buffer view %v, stride %v). File: %v", view, stride, path)
            return false
        }
    }
    for &v in data.buffer_views do v.byte_stride = nil
    return true
}

@(private="file")
gltf_element_size :: proc(a: gltf2.Accessor) -> gltf2.Integer {
    component: gltf2.Integer
    switch a.component_type {
        case .Byte, .Unsigned_Byte:   component = 1
        case .Short, .Unsigned_Short: component = 2
        case .Unsigned_Int, .Float:   component = 4
    }
    count: gltf2.Integer
    switch a.type {
        case .Scalar:  count = 1
        case .Vector2: count = 2
        case .Vector3: count = 3
        case .Vector4: count = 4
        case .Matrix2: count = 4
        case .Matrix3: count = 9
        case .Matrix4: count = 16
    }
    return component * count
}

// A node's local transform as TRS, glTF space. A node given as a matrix is decomposed (no shear).
@(private="file")
gltf_node_pose :: proc(n: gltf2.Node) -> Joint_Pose {
    m := n.mat
    if m == mat4(1) do return {t = n.translation, r = n.rotation, s = n.scale}
    s: vec3
    for c in 0..<3 do s[c] = la.length(vec3{m[0, c], m[1, c], m[2, c]})
    r: mat3
    for c in 0..<3 do for row in 0..<3 do r[row, c] = m[row, c] / s[c]
    return {t = mat_translation(m), r = la.quaternion_from_matrix3_f32(r), s = s}
}

// Imports every skin of a glTF as a skeleton. Joints are reordered parent before child. The result, per
// glTF skin, is temp.
asset_import_skeletons :: proc(data: ^gltf2.Data, path, file_key: string, node_world: []mat4, node_reached: []bool) -> []Gltf_Skin {
    out := make([]Gltf_Skin, len(data.skins), context.temp_allocator)
    parent_node := make([]int, len(data.nodes), context.temp_allocator)
    for &p in parent_node do p = -1
    for n, i in data.nodes do for c in n.children do parent_node[c] = i

    for skin, si in data.skins {
        gs := &out[si]
        gs.skeleton = NO_SKELETON
        if len(skin.joints) > MAX_JOINTS {
            log.errorf("Skin %v has %v joints, more than MAX_JOINTS (%v). File: %v", si, len(skin.joints), MAX_JOINTS, path)
            continue
        }
        slot_of := make(map[int]int, len(skin.joints), context.temp_allocator)   // glTF node → skin slot
        for node, slot in skin.joints do slot_of[int(node)] = slot

        // Parent before child: depth-first from every top joint (one whose parent isn't in the skin).
        order := make([dynamic]int, 0, len(skin.joints), context.temp_allocator)   // skeleton joint → glTF node
        top_parent := -2
        visit :: proc(data: ^gltf2.Data, node: int, slot_of: map[int]int, order: ^[dynamic]int) {
            append(order, node)
            for c in data.nodes[node].children do if int(c) in slot_of do visit(data, int(c), slot_of, order)
        }
        for node in skin.joints {
            p := parent_node[node]
            if p in slot_of do continue
            if top_parent != -2 && p != top_parent {
                log.warnf("Skin %v's top joints have different parents; using the first's. File: %v", si, path)
            }
            if top_parent == -2 do top_parent = p
            visit(data, int(node), slot_of, &order)
        }
        if !node_reached[skin.joints[0]] {
            log.errorf("Skin %v's joints aren't in the default scene. File: %v", si, path)
            continue
        }

        // Above the top joints: its rotation/scale stays with the skeleton (root_parent), its translation is
        // where the kit lays the model out (like a static mesh's node).
        parent := top_parent >= 0 ? node_world[top_parent] : mat4(1)
        origin := mat_translation(parent)
        parent_rs := parent
        parent_rs[0, 3], parent_rs[1, 3], parent_rs[2, 3] = 0, 0, 0
        to_model := la.matrix4_translate_f32(-origin)

        ibm: []matrix[4, 4]f32
        if acc, ok := skin.inverse_bind_matrices.?; ok {
            ibm, _ = gltf2.buffer_slice(data, acc).([]matrix[4, 4]f32)
        }

        arena := context.allocator
        skel := Skeleton{
            key         = fmt.aprintf("%v:%v", file_key, skin.name.? or_else fmt.tprintf("skin%v", si)),
            parents     = make([]u8, len(order), arena),
            names       = make([]string, len(order), arena),
            rest        = make([]Joint_Pose, len(order), arena),
            inv_bind    = make([]mat4, len(order), arena),
            root_parent = REFLECT * parent_rs * REFLECT,
        }
        gs.slot_joint = make([]u8, len(skin.joints), context.temp_allocator)
        gs.node_joint = make(map[int]u8, len(order), context.temp_allocator)
        gs.bind = make([]mat4, len(skin.joints), context.temp_allocator)
        gs.origin = {-origin.x, origin.y, origin.z}
        for node, j in order do gs.node_joint[node] = u8(j)
        for node, j in order {
            n := data.nodes[node]
            slot := slot_of[node]
            p := parent_node[node]
            skel.parents[j] = p in gs.node_joint ? gs.node_joint[p] : NO_JOINT
            skel.names[j] = strings.clone(n.name.? or_else fmt.tprintf("joint%v", j))
            skel.rest[j] = pose_reflect(gltf_node_pose(n))
            rest_model := to_model * node_world[node]   // glTF space
            skel.inv_bind[j] = REFLECT * la.matrix4_inverse_f32(rest_model) * REFLECT
            gs.slot_joint[slot] = u8(j)
            gs.bind[slot] = rest_model * (slot < len(ibm) ? ibm[slot] : 1)
        }
        append(&asset_system.skeletons, skel)
        gs.skeleton = u32(len(asset_system.skeletons) - 1)
    }
    return out
}

// A skinned primitive's JOINTS_0 / WEIGHTS_0 appended to vertex_skins. `bind` (temp) is per vertex the
// glTF-space matrix that puts it in the rest pose in model space; the caller bakes positions and normals by it,
// so an unskinned draw of the mesh is its rest pose. Returns the mesh's skin_offset, or NO_SKIN.
asset_import_skin_vertices :: proc(data: ^gltf2.Data, prim: gltf2.Mesh_Primitive, skin: Gltf_Skin, count: u32, path: string) -> (offset: u32, bind: []mat4) {
    joints_acc, has_joints := prim.attributes["JOINTS_0"]
    weights_acc, has_weights := prim.attributes["WEIGHTS_0"]
    if !has_joints || !has_weights {
        log.errorf("Skinned primitive without JOINTS_0 / WEIGHTS_0. File: %v", path)
        return NO_SKIN, nil
    }
    joints := make([][4]u16, count, context.temp_allocator)
    #partial switch v in gltf2.buffer_slice(data, joints_acc) {
        case [][4]u8:  for j, i in v do joints[i] = {u16(j[0]), u16(j[1]), u16(j[2]), u16(j[3])}
        case [][4]u16: copy(joints, v)
        case:
            log.errorf("Unsupported JOINTS_0 format. File: %v", path)
            return NO_SKIN, nil
    }
    weights := make([][4]f32, count, context.temp_allocator)
    #partial switch v in gltf2.buffer_slice(data, weights_acc) {
        case [][4]f32: copy(weights, v)
        case [][4]u8:  for w, i in v do weights[i] = la.array_cast(w, f32) / 255
        case [][4]u16: for w, i in v do weights[i] = la.array_cast(w, f32) / 65535
        case:
            log.errorf("Unsupported WEIGHTS_0 format. File: %v", path)
            return NO_SKIN, nil
    }

    offset = u32(len(asset_system.vertex_skins))
    bind = make([]mat4, count, context.temp_allocator)
    for i in 0..<int(count) {
        sv: Skin_Vertex
        w := weights[i]
        total := w[0] + w[1] + w[2] + w[3]
        if total <= 0 do w, total = {1, 0, 0, 0}, 1
        w /= total
        m: mat4
        for k in 0..<4 {
            slot := int(joints[i][k])
            if slot >= len(skin.slot_joint) do slot, w[k] = 0, 0
            sv.joints[k] = skin.slot_joint[slot]
            m += skin.bind[slot] * mat4(w[k])   // scalar × matrix: a diagonal matrix in Odin
        }
        // unorm8, rounded, then the largest weight takes the remainder so they sum to 255 exactly.
        sum, largest := 0, 0
        for k in 0..<4 {
            sv.weights[k] = u8(math.round(w[k] * 255))
            sum += int(sv.weights[k])
            if sv.weights[k] > sv.weights[largest] do largest = k
        }
        sv.weights[largest] = u8(int(sv.weights[largest]) + 255 - sum)
        append(&asset_system.vertex_skins, sv)
        bind[i] = m
    }
    return
}

// A kit's clips file (`knight.gltf` → `knight.clips`, next to it): how its animations become clips, and their
// events. Written by the 3ds Max script (tools/max/blimp_clips.ms) or by hand:
//
//     fps 30              frames per second of every number below (default 30)
//     [Idle 0 30]         clip Idle = frames 0 to 30 of the glTF's animation (Max exports one timeline)
//     [Walk 40 64]
//     footstep 46         an event, at a frame of that same timeline
//     [Survey]            no range: the glTF's own animation named Survey, whole; its events count from its start
//
// '#' starts a comment. Without the file every glTF animation is a clip, whole, with no events. With ranges, the
// animation they're cut from (the glTF's first) isn't a clip itself.
Clips_Section :: struct {
    name:   string,
    ranged: bool,
    start, end: f32,   // frames
    events: [dynamic]Clips_Event,
}

Clips_Event :: struct {
    name:  string,
    frame: f32,
}

@(private="file")
clips_file_read :: proc(path: string) -> (fps: f32, sections: [dynamic]Clips_Section, clips_path: string) {
    fps = 30
    full_path := strings.concatenate({path[:len(path) - len(filepath.ext(path))], ".clips"}, context.temp_allocator)
    clips_path = asset_key(full_path, context.temp_allocator)   // for the log
    sections = make([dynamic]Clips_Section, context.temp_allocator)
    data, err := os.read_entire_file(full_path, context.temp_allocator)
    if err != nil do return
    text := string(data)
    line_no := 0
    for line in strings.split_lines_iterator(&text) {
        line_no += 1
        l := strings.trim_space(line)
        if hash := strings.index_byte(l, '#'); hash >= 0 do l = strings.trim_space(l[:hash])
        if l == "" do continue
        fields := strings.fields(l, context.temp_allocator)
        bad := false
        if l[0] == '[' && l[len(l) - 1] == ']' {
            head := strings.fields(l[1:len(l) - 1], context.temp_allocator)
            sec := Clips_Section{events = make([dynamic]Clips_Event, context.temp_allocator)}
            switch len(head) {
                case 1: sec.name = head[0]
                case 3:
                    a, aok := strconv.parse_f32(head[1])
                    b, bok := strconv.parse_f32(head[2])
                    sec.name, sec.ranged, sec.start, sec.end = head[0], true, a, b
                    bad = !aok || !bok || b <= a
                case: bad = true
            }
            if !bad do append(&sections, sec)
        } else if len(fields) == 2 && fields[0] == "fps" && len(sections) == 0 {
            v, ok := strconv.parse_f32(fields[1])
            if ok && v > 0 do fps = v
            bad = !ok || v <= 0
        } else if len(fields) == 2 && len(sections) > 0 {
            frame, ok := strconv.parse_f32(fields[1])
            if ok do append(&sections[len(sections) - 1].events, Clips_Event{fields[0], frame})
            bad = !ok
        } else {
            bad = true
        }
        if bad do log.warnf("%v:%v: expected 'fps N', '[Clip]', '[Clip start end]' or 'event frame', got '%v'", clips_path, line_no, l)
    }
    return
}

// Bakes the glTF's animations into clips of the skeletons they drive, as its clips file says (above), and gives
// them their events. Clips are made in place: the shallowest translated joint's straight-line travel over the
// clip is taken out (its sway stays) and kept as root_speed, so gameplay moves the character and a script can
// match playback to its speed.
asset_import_clips :: proc(data: ^gltf2.Data, path, file_key: string, skins: []Gltf_Skin) {
    fps, sections, clips_path := clips_file_read(path)
    ranged := false
    for sec in sections do ranged ||= sec.ranged
    if ranged && len(data.animations) == 0 do log.warnf("%v cuts clips, but %v has no animation", clips_path, path)

    first := len(asset_system.clips)
    for anim, ai in data.animations {
        name := anim.name.? or_else fmt.tprintf("anim%v", ai)
        duration: f32
        for s in anim.samplers {
            if times, ok := gltf2.buffer_slice(data, s.input).([]f32); ok && len(times) > 0 do duration = max(duration, times[len(times) - 1])
        }
        if !(ranged && ai == 0) {
            asset_bake_clip(data, anim, skins, name, 0, duration, path, file_key)
            continue
        }
        for sec in sections do if sec.ranged {
            t0, t1 := sec.start / fps, sec.end / fps
            if t1 > duration + 0.5 / fps {
                log.warnf("%v: clip %v ends at frame %v, after the animation (%v frames); cut short", clips_path, sec.name, sec.end, duration * fps)
            }
            asset_bake_clip(data, anim, skins, sec.name, min(t0, duration), min(t1, duration), path, file_key)
        }
    }

    // Events, from frames on the clip's source timeline to seconds into the clip.
    for sec in sections {
        clip: ^Clip
        for &c in asset_system.clips[first:] do if c.name == sec.name do clip = &c
        if clip == nil {
            log.warnf("%v: no clip '%v' in %v", clips_path, sec.name, file_key)
            continue
        }
        if len(sec.events) == 0 do continue
        events := make([]Anim_Event, len(sec.events))
        for ev, i in sec.events {
            t := (ev.frame - (sec.ranged ? sec.start : 0)) / fps
            if t < 0 || t > clip.duration + 0.001 {
                log.warnf("%v: event %v at frame %v is outside clip %v; clamped", clips_path, ev.name, ev.frame, sec.name)
            }
            events[i] = {time = clamp(t, 0, clip.duration), name = strings.clone(ev.name)}
        }
        slice.sort_by(events, proc(a, b: Anim_Event) -> bool { return a.time < b.time })
        clip.events = events
    }
}

// One clip: the animation from t0 to t1 (seconds), resampled at about CLIP_RATE, made in place, added to the
// skeleton the animation drives.
@(private="file")
asset_bake_clip :: proc(data: ^gltf2.Data, anim: gltf2.Animation, skins: []Gltf_Skin, name: string, t0, t1: f32, path, file_key: string) {
    // The skin this animation drives: the first whose joints a channel targets.
    skin_index := -1
    find: for ch in anim.channels {
        node, ok := ch.target.node.?
        if !ok do continue
        for s, si in skins do if s.skeleton != NO_SKELETON && int(node) in s.node_joint {
            skin_index = si
            break find
        }
    }
    if skin_index < 0 {
        log.warnf("Animation '%v' drives no skinned joint; skipped (node animation isn't supported). File: %v", name, path)
        return
    }
    gs := skins[skin_index]
    skel := &asset_system.skeletons[gs.skeleton]
    n := len(skel.parents)
    if name in skel.clips {
        log.errorf("Duplicate clip '%v' on skeleton '%v'. File: %v", name, skel.key, path)
        return
    }

    duration := t1 - t0
    frame_count := max(2, u32(math.round(duration * CLIP_RATE)) + 1)

    // Every joint's local pose per frame, glTF space: the rest pose with the channels sampled over it.
    poses := make([]Joint_Pose, int(frame_count) * n, context.allocator)
    translated := make([]bool, n, context.temp_allocator)
    for f in 0..<frame_count {
        frame := poses[int(f) * n:][:n]
        for j in 0..<n do frame[j] = pose_reflect(skel.rest[j])   // glTF space; reflected back below
        t := t0 + duration * f32(f) / f32(frame_count - 1)
        for ch in anim.channels {
            node, ok := ch.target.node.?
            if !ok do continue
            j, is_joint := gs.node_joint[int(node)]
            if !is_joint do continue
            s := anim.samplers[ch.sampler]
            times, _ := gltf2.buffer_slice(data, s.input).([]f32)
            switch ch.target.path {
                case .Translation:
                    if v, vok := gltf2.buffer_slice(data, s.output).([][3]f32); vok do frame[j].t = gltf_sample_vec3(times, v, s.interpolation, t)
                    translated[j] = true
                case .Scale:
                    if v, vok := gltf2.buffer_slice(data, s.output).([][3]f32); vok do frame[j].s = gltf_sample_vec3(times, v, s.interpolation, t)
                case .Rotation:
                    if v, vok := gltf2.buffer_slice(data, s.output).([][4]f32); vok {
                        frame[j].r = gltf_sample_quat(times, v, s.interpolation, t)
                    } else {
                        log.warnf("Animation '%v': only float rotations are supported. File: %v", name, path)
                    }
                case .Weights:   // morph targets: not supported
            }
        }
        for &p in frame do p = pose_reflect(p)
    }

    // In place: the shallowest translated joint (parents come first) loses its straight-line XZ travel.
    root_speed: f32
    motion := -1
    for j in 0..<n do if translated[j] { motion = j; break }
    if motion >= 0 {
        model := make([]mat4, n, context.temp_allocator)
        first := poses[:n]
        last := poses[int(frame_count - 1) * n:][:n]
        skeleton_model_matrices(skel, first, model)
        start := mat_translation(model[motion])
        skeleton_model_matrices(skel, last, model)
        travel := mat_translation(model[motion]) - start
        travel.y = 0
        if duration > 0 do root_speed = la.length(travel) / duration
        if la.length(travel) > 0 {
            for f in 0..<frame_count {
                frame := poses[int(f) * n:][:n]
                skeleton_model_matrices(skel, frame, model)
                pos := mat_translation(model[motion]) - travel * (f32(f) / f32(frame_count - 1))
                p := skel.parents[motion]
                parent := p == NO_JOINT ? skel.root_parent : model[p]
                frame[motion].t = (la.matrix4_inverse_f32(parent) * vec4{pos.x, pos.y, pos.z, 1}).xyz
            }
        }
    }

    append(&asset_system.clips, Clip{
        key = fmt.aprintf("%v:%v", file_key, name), name = strings.clone(name), skeleton = gs.skeleton,
        duration = duration, frame_count = frame_count, poses = poses, root_speed = root_speed,
    })
    skel.clips[strings.clone(name)] = u32(len(asset_system.clips) - 1)
}

// Key k with times[k] ≤ t < times[k+1], and how far t is between them (glTF sampler input).
@(private="file")
gltf_key :: proc(times: []f32, t: f32) -> (k: int, frac: f32, dt: f32) {
    if len(times) < 2 || t <= times[0] do return 0, 0, 0
    if t >= times[len(times) - 1] do return len(times) - 1, 0, 0
    for k + 1 < len(times) && times[k + 1] <= t do k += 1
    dt = times[k + 1] - times[k]
    return k, dt > 0 ? (t - times[k]) / dt : 0, dt
}

@(private="file")
gltf_sample_vec3 :: proc(times: []f32, v: [][3]f32, interp: gltf2.Interpolation_Algorithm, t: f32) -> vec3 {
    k, u, dt := gltf_key(times, t)
    switch interp {
        case .Step:   return v[k]
        case .Linear: return k + 1 < len(v) && u > 0 ? la.lerp(v[k], v[k + 1], u) : v[k]
        case .Cubic_Spline:   // per key: in-tangent, value, out-tangent
            if k + 1 >= len(times) || u == 0 do return v[3*k + 1]
            return gltf_hermite(v[3*k + 1], v[3*k + 2] * dt, v[3*(k + 1) + 1], v[3*(k + 1)] * dt, u)
    }
    return v[k]
}

@(private="file")
gltf_sample_quat :: proc(times: []f32, v: [][4]f32, interp: gltf2.Interpolation_Algorithm, t: f32) -> quat {
    q :: proc(a: [4]f32) -> quat { return quaternion(x = a.x, y = a.y, z = a.z, w = a.w) }
    k, u, dt := gltf_key(times, t)
    switch interp {
        case .Step:   return q(v[k])
        case .Linear: return k + 1 < len(v) && u > 0 ? la.quaternion_slerp_f32(q(v[k]), q(v[k + 1]), u) : q(v[k])
        case .Cubic_Spline:
            if k + 1 >= len(times) || u == 0 do return la.normalize(q(v[3*k + 1]))
            return la.normalize(q(gltf_hermite(v[3*k + 1], v[3*k + 2] * dt, v[3*(k + 1) + 1], v[3*(k + 1)] * dt, u)))
    }
    return q(v[k])
}

@(private="file")
gltf_hermite :: proc(p0, m0, p1, m1: $T, t: f32) -> T {
    t2, t3 := t*t, t*t*t
    return p0 * (2*t3 - 3*t2 + 1) + m0 * (t3 - 2*t2 + t) + p1 * (-2*t3 + 3*t2) + m1 * (t3 - t2)
}
