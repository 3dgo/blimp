// AUTO GENERATED. DO NOT EDIT — edit entity_schema.ini instead.

package blimp

Entity :: struct {
    handle: Entity_Handle `hidden, noserialize`,
    // Editor selection. On the entity so undo snapshots carry it and delete/paste need no
    // bookkeeping; never saved or copied (noserialize), never shown (hidden). (editor_selection.odin,
    // editor_world.odin)
    selected: bool `hidden, noserialize`,
    name: sbuf64 `identity`,
    // Editor icon in the entity and template lists: the hex codepoint of a Material Symbols glyph
    // (e.g. E835; the codepoints are in Google's .codepoints list, as in editor_icons.odin). Empty: a
    // light or camera shows its type's icon, anything else none.
    icon: sbuf64 `widget:icon`,
    basic_static_flags: EntityBasicStaticFlags,
    basic_flags: EntityBasicFlags,
    position: vec3 `section:Transform`,
    rotation: quat `section:Transform`,
    scale: vec3 `section:Transform`,
    model: string `widget:model, section:Render`,
    // A clip of the model's skeleton (its short name, e.g. Walk) the entity loops while playing when
    // its script outputs no pose (claude/animation.md). Empty: the rest pose.
    anim: sbuf64 `section:Render`,
    // How the model's surfaces take light (the ShadingModel members; shading.slang). Default: the
    // level's World Settings → Shading.
    shading: EntityShading `section:Render`,
    // How the model's pixels combine with what's behind them. Alpha and Additive don't write depth or
    // cast shadows, and draw after everything opaque in entity order, unsorted.
    blend: EntityBlend `section:Render`,
    // Camera and light, flat on the entity. A kind is which type is set; the shared fields mean what
    // they mean for that kind. Something that needs both (a flashlight on a camera) is two entities.
    // No aspect: a camera takes it from the target it renders into, and shadow maps are square.
    camera_type: EntityCameraType `section:Camera_Light`,
    light_type: EntityLightType `section:Camera_Light`,
    // Light colour, stored linear; the picker shows and edits it as sRGB (like Unity's).
    color: vec3 `widget:linear_color, section:Render`,
    intensity: f32 `section:Render`,
    // Degrees. Perspective camera: vertical field of view. Spot light: cone angle (also its shadow
    // frustum).
    fov: f32 `section:Dimensions`,
    // Degrees. Spot light: inner cone angle — full intensity inside it, fading to zero at fov
    // (Unity's inner spot angle; Unreal's inner cone angle, but as a full angle). Clamped to fov.
    inner_fov: f32 `section:Dimensions`,
    // Cylinder light: a spot light with a cylinder-shaped beam instead of a cone. Parallel rays from
    // a disc at the entity along its +Z; radius is the beam's, full intensity inside inner_radius and
    // fading to zero at radius (as fov / inner_fov do for a spot). Inner is clamped to radius.
    radius: f32 `section:Dimensions`,
    inner_radius: f32 `section:Dimensions`,
    // How a point / spot / cylinder light fades over its range (see range).
    falloff: EntityLightFalloff `section:Camera_Light`,
    // The box the entity's projection or volume covers. Orthographic camera: y = view height (the
    // width comes from the target's aspect). Directional light: x, y = shadow area, z = its depth.
    // Later: trigger, fog and other volumes.
    size: vec3 `section:Dimensions`,
    // Near, far. Camera: clip planes. Point / spot / cylinder light: inner, outer distance of its
    // falloff — zero at y. Linear and Smooth are full intensity inside x. Inverse Square is
    // intensity / d² (intensity is the light at 1 unit), held flat inside x (the source's radius)
    // and windowed to zero at y. A cylinder's distance is along its beam, from its disc.
    range: vec2 `section:Dimensions`,
    shadow: bool `section:Camera_Light`,
    // Which light group the light belongs to (World Settings → Light Groups): 0 = static, always
    // on; 1–4 can be dimmed or switched off at runtime (Lua World.set_light_group), realtime and
    // baked light together.
    light_group: i32 `section:Camera_Light`,
    // Light: scales its baked bounce (the probes) without touching its direct light. Whether it bakes
    // at all is Static + Cast Indirect in its static flags, as for geometry.
    indirect: f32 `section:Camera_Light`,
    // Point / spot light: scales the glow it makes in the fog (World Settings → Fog → Lamp
    // Halos), without touching its light on surfaces. 0 = no halo.
    halo: f32 `section:Camera_Light`,
    // Sound (world_sound.odin): a sound file's project path (.wav .ogg .mp3 .flac under assets/,
    // loaded at startup). The entity plays it in play mode: when the game starts if Play On Start, or
    // when Lua calls Entity.play_sound. While it plays it follows the entity. Positional: full volume
    // within range.x, fading linearly to silent at range.y; otherwise the same everywhere (music,
    // UI).
    sound: string `widget:sound, section:Sound`,
    volume: f32 `section:Sound`,
    sound_flags: EntitySoundFlags `section:Sound`,
    // What the entity collides as while playing (world_physics.odin; claude/gameplay.md → Physics),
    // cheapest first. Box: the model's bounds. Collision Mesh: the kit's <model>_col mesh, authored
    // in the DCC (Play warns when the model has none). Render Mesh: the model's own triangles, every
    // one of them. Static entities are static bodies; anything else follows its entity every frame
    // (kinematic), so a gate a script moves still blocks. Needs a model.
    collision: EntityCollision `section:Physics`,
    // Metres per second, for game code: Lua reads and writes it (a character's fall and jump speed
    // between frames, since Lua keeps no state). Nothing in the engine moves an entity by it.
    velocity: vec3 `noserialize, section:Physics`,
}

EntitySection :: enum u64 {
    Transform,
    Render,
    Dimensions,
    Camera_Light,
    Sound,
    Physics,
}

EntityCollision :: enum u64 {
    None,
    Box,
    Collision_Mesh,
    Render_Mesh,
}

EntityCameraType :: enum u64 {
    None,
    Perspective,
    Orthographic,
}

EntityLightType :: enum u64 {
    None,
    Directional,
    Point,
    Spot,
    Cylinder,
}

EntityLightFalloff :: enum u64 {
    // Physical: intensity / d², windowed to zero at range.y (Unreal, Unity URP).
    Inverse_Square,
    // Full inside range.x, straight down to zero at range.y.
    Linear,
    // Full inside range.x, smoothstep down to zero at range.y: no visible edge at either end.
    Smooth,
}

// A level's shading (World Settings) and what an entity's shading resolves to. Cheapest first; member
// order is SHADING_* in shading.slang.
ShadingModel :: enum u64 {
    // Texture × colour, no light.
    Unlit,
    // Lit per vertex, interpolated across the face, diffuse only: the PS1's. Shadows per pixel.
    Gouraud,
    // Lit per pixel with the mesh's smooth normals, diffuse only: Gouraud without the vertex
    // artifacts.
    Lambert,
    // Lit per pixel with the face's normal, diffuse only: faceted.
    Flat,
    // Lit per pixel, with a specular highlight.
    Phong,
}

// ShadingModel plus Default (the level's).
EntityShading :: enum u64 {
    Default,
    Unlit,
    Gouraud,
    Lambert,
    Flat,
    Phong,
}

// Draw order is member order: each is a draw bucket with its own PSO (render_dx.odin).
EntityBlend :: enum u64 {
    Opaque,
    // Opaque, but pixels under half alpha are cut out (fences, foliage). Shadows still see the whole
    // quad.
    Cutout,
    Alpha,
    Additive,
}

EntityBasicStaticFlag :: enum u64 {
    Static,
    Renderable,
    // Static geometry that blocks and bounces light in the probe bake (claude/rendering.md, Baker).
    // Off for clutter that would only add noise; entities without Static never bake whatever this
    // says.
    Cast_Indirect,
}
EntityBasicStaticFlags :: bit_set[EntityBasicStaticFlag; u64]

EntityBasicFlag :: enum u64 {
    Enabled,
    Hidden,
}
EntityBasicFlags :: bit_set[EntityBasicFlag; u64]

EntitySoundFlag :: enum u64 {
    Play_On_Start,
    Loop,
    Positional,
}
EntitySoundFlags :: bit_set[EntitySoundFlag; u64]

// Applies each schema `default` to a fresh entity (fields with no default keep zero).
entity_apply_defaults :: proc(e: ^Entity) {
    e.basic_static_flags = {.Static, .Renderable, .Cast_Indirect}
    e.basic_flags = {.Enabled}
    e.position = {0, 0, 0}
    e.rotation = transmute(quat)[4]f32{0, 0, 0, 1}
    e.scale = {1, 1, 1}
    e.shading = .Default
    e.blend = .Opaque
    e.camera_type = .None
    e.light_type = .None
    e.color = {1, 1, 1}
    e.intensity = 1
    e.fov = 60
    e.inner_fov = 40
    e.radius = 1
    e.inner_radius = 0.75
    e.falloff = .Inverse_Square
    e.size = {10, 10, 50}
    e.range = {0.1, 20}
    e.shadow = false
    e.light_group = 0
    e.indirect = 1
    e.halo = 1
    e.volume = 1
    e.sound_flags = {.Positional}
    e.collision = .Collision_Mesh
    e.velocity = {0, 0, 0}
}

// A field's label in every language (empty where it has none).
entity_field_labels :: proc(name: string) -> (l: [Lang]string) {
    switch name {
    case "name": l = {.EN = "Name", .ZH = "名称"}
    case "icon": l = {.EN = "Icon", .ZH = "图标"}
    case "basic_static_flags": l = {.EN = "Static Flags", .ZH = "静态标志"}
    case "basic_flags": l = {.EN = "Flags", .ZH = "基本标志"}
    case "position": l = {.EN = "Position", .ZH = "位置"}
    case "rotation": l = {.EN = "Rotation", .ZH = "旋转"}
    case "scale": l = {.EN = "Scale", .ZH = "缩放"}
    case "model": l = {.EN = "Model", .ZH = "模型"}
    case "anim": l = {.EN = "Animation", .ZH = "动画"}
    case "shading": l = {.EN = "Shading", .ZH = "着色"}
    case "blend": l = {.EN = "Blend", .ZH = "混合"}
    case "camera_type": l = {.EN = "Camera", .ZH = "相机"}
    case "light_type": l = {.EN = "Light", .ZH = "灯光"}
    case "color": l = {.EN = "Color", .ZH = "颜色"}
    case "intensity": l = {.EN = "Intensity", .ZH = "强度"}
    case "fov": l = {.EN = "FOV", .ZH = "视角"}
    case "inner_fov": l = {.EN = "Inner FOV", .ZH = "内视角"}
    case "radius": l = {.EN = "Radius", .ZH = "半径"}
    case "inner_radius": l = {.EN = "Inner Radius", .ZH = "内半径"}
    case "falloff": l = {.EN = "Falloff", .ZH = "衰减"}
    case "size": l = {.EN = "Size", .ZH = "尺寸"}
    case "range": l = {.EN = "Range", .ZH = "范围"}
    case "shadow": l = {.EN = "Cast Shadow", .ZH = "投射阴影"}
    case "light_group": l = {.EN = "Light Group", .ZH = "光源组"}
    case "indirect": l = {.EN = "Indirect Intensity", .ZH = "间接光强度"}
    case "halo": l = {.EN = "Halo Intensity", .ZH = "光晕强度"}
    case "sound": l = {.EN = "Sound", .ZH = "声音"}
    case "volume": l = {.EN = "Volume", .ZH = "音量"}
    case "sound_flags": l = {.EN = "Sound Flags", .ZH = "声音标志"}
    case "collision": l = {.EN = "Collision", .ZH = "碰撞"}
    case "velocity": l = {.EN = "Velocity", .ZH = "速度"}
    }
    return
}

// Localized field label for the current language; ok=false if none.
entity_field_label :: proc(name: string) -> (string, bool) {
    s := entity_field_labels(name)[loc_lang]
    return s, s != ""
}

// An enum/flags member's label in every language, keyed on the type name (empty where it has none).
entity_flag_item_labels :: proc(enum_type: string, member: string) -> (l: [Lang]string) {
    switch enum_type {
    case "EntitySection":
        switch member {
        case "Transform": l = {.EN = "Transform", .ZH = "变换"}
        case "Render": l = {.EN = "Render", .ZH = "渲染"}
        case "Dimensions": l = {.EN = "Dimensions", .ZH = "尺度"}
        case "Camera_Light": l = {.EN = "Camera & Light", .ZH = "相机与灯光"}
        case "Sound": l = {.EN = "Sound", .ZH = "声音"}
        case "Physics": l = {.EN = "Physics", .ZH = "物理"}
        }
    case "EntityCollision":
        switch member {
        case "None": l = {.EN = "None", .ZH = "无"}
        case "Box": l = {.EN = "Box", .ZH = "包围盒"}
        case "Collision_Mesh": l = {.EN = "Collision Mesh (_col)", .ZH = "碰撞网格（_col）"}
        case "Render_Mesh": l = {.EN = "Render Mesh", .ZH = "渲染网格"}
        }
    case "EntityCameraType":
        switch member {
        case "None": l = {.EN = "None", .ZH = "无"}
        case "Perspective": l = {.EN = "Perspective", .ZH = "透视"}
        case "Orthographic": l = {.EN = "Orthographic", .ZH = "正交"}
        }
    case "EntityLightType":
        switch member {
        case "None": l = {.EN = "None", .ZH = "无"}
        case "Directional": l = {.EN = "Directional", .ZH = "平行光"}
        case "Point": l = {.EN = "Point", .ZH = "点光源"}
        case "Spot": l = {.EN = "Spot", .ZH = "聚光灯"}
        case "Cylinder": l = {.EN = "Cylinder", .ZH = "圆柱光"}
        }
    case "EntityLightFalloff":
        switch member {
        case "Inverse_Square": l = {.EN = "Inverse Square", .ZH = "平方反比"}
        case "Linear": l = {.EN = "Linear", .ZH = "线性"}
        case "Smooth": l = {.EN = "Smooth", .ZH = "平滑"}
        }
    case "ShadingModel":
        switch member {
        case "Unlit": l = {.EN = "Unlit", .ZH = "无光照"}
        case "Gouraud": l = {.EN = "Gouraud", .ZH = "高洛德"}
        case "Lambert": l = {.EN = "Lambert", .ZH = "兰伯特"}
        case "Flat": l = {.EN = "Flat", .ZH = "平面"}
        case "Phong": l = {.EN = "Phong", .ZH = "冯氏"}
        }
    case "EntityShading":
        switch member {
        case "Default": l = {.EN = "Default", .ZH = "默认"}
        case "Unlit": l = {.EN = "Unlit", .ZH = "无光照"}
        case "Gouraud": l = {.EN = "Gouraud", .ZH = "高洛德"}
        case "Lambert": l = {.EN = "Lambert", .ZH = "兰伯特"}
        case "Flat": l = {.EN = "Flat", .ZH = "平面"}
        case "Phong": l = {.EN = "Phong", .ZH = "冯氏"}
        }
    case "EntityBlend":
        switch member {
        case "Opaque": l = {.EN = "Opaque", .ZH = "不透明"}
        case "Cutout": l = {.EN = "Cutout", .ZH = "镂空"}
        case "Alpha": l = {.EN = "Alpha", .ZH = "半透明"}
        case "Additive": l = {.EN = "Additive", .ZH = "叠加"}
        }
    case "EntityBasicStaticFlag":
        switch member {
        case "Static": l = {.EN = "Static", .ZH = "静态"}
        case "Renderable": l = {.EN = "Renderable", .ZH = "可渲染"}
        case "Cast_Indirect": l = {.EN = "Cast Indirect", .ZH = "投射间接光"}
        }
    case "EntityBasicFlag":
        switch member {
        case "Enabled": l = {.EN = "Enabled", .ZH = "启用"}
        case "Hidden": l = {.EN = "Hidden", .ZH = "隐藏"}
        }
    case "EntitySoundFlag":
        switch member {
        case "Play_On_Start": l = {.EN = "Play On Start", .ZH = "开始时播放"}
        case "Loop": l = {.EN = "Loop", .ZH = "循环"}
        case "Positional": l = {.EN = "Positional", .ZH = "空间定位"}
        }
    }
    return
}

// Localized enum/flags member label, keyed on the type name; ok=false if none.
entity_flag_item_label :: proc(enum_type: string, member: string) -> (string, bool) {
    s := entity_flag_item_labels(enum_type, member)[loc_lang]
    return s, s != ""
}

// Localized struct member label, keyed on the struct type name; ok=false if none.
entity_struct_member_label :: proc(struct_type: string, member: string) -> (string, bool) {
    l: [Lang]string
    switch struct_type {
    }
    s := l[loc_lang]
    return s, s != ""
}

