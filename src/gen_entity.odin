// AUTO GENERATED. DO NOT EDIT — edit entity_schema.ini instead.

package blimp

Entity :: struct {
    handle: Entity_Handle `hidden, noserialize`,
    selected: bool `hidden, noserialize`,
    name: sbuf64 `identity`,
    icon: sbuf64 `widget:icon`,
    basic_static_flags: EntityBasicStaticFlags,
    basic_flags: EntityBasicFlags,
    position: vec3 `placement`,
    rotation: quat `placement`,
    scale: vec3 `placement`,
    model: string `widget:model`,
    camera_type: EntityCameraType,
    light_type: EntityLightType,
    color: vec3 `widget:linear_color`,
    intensity: f32,
    fov: f32,
    inner_fov: f32,
    radius: f32,
    inner_radius: f32,
    falloff: EntityLightFalloff,
    size: vec3,
    range: vec2,
    shadow: bool,
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
    Inverse_Square,
    Linear,
    Smooth,
}

EntityBasicStaticFlag :: enum u64 {
    Static,
    Renderable,
}
EntityBasicStaticFlags :: bit_set[EntityBasicStaticFlag; u64]

EntityBasicFlag :: enum u64 {
    Enabled,
    Hidden,
}
EntityBasicFlags :: bit_set[EntityBasicFlag; u64]

// Applies each schema `default` to a fresh entity (fields with no default keep zero).
entity_apply_defaults :: proc(e: ^Entity) {
    e.basic_static_flags = {.Static, .Renderable}
    e.basic_flags = {.Enabled}
    e.position = {0, 0, 0}
    e.rotation = transmute(quat)[4]f32{0, 0, 0, 1}
    e.scale = {1, 1, 1}
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
}

// Localized field label for the current language; ok=false if none.
entity_field_label :: proc(name: string) -> (string, bool) {
    l: [Lang]string
    switch name {
    case "name": l = {.EN = "Name", .ZH = "名称"}
    case "icon": l = {.EN = "Icon", .ZH = "图标"}
    case "basic_static_flags": l = {.EN = "Static Flags", .ZH = "静态标志"}
    case "basic_flags": l = {.EN = "Flags", .ZH = "基本标志"}
    case "position": l = {.EN = "Position", .ZH = "位置"}
    case "rotation": l = {.EN = "Rotation", .ZH = "旋转"}
    case "scale": l = {.EN = "Scale", .ZH = "缩放"}
    case "model": l = {.EN = "Model", .ZH = "模型"}
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
    }
    s := l[loc_lang]
    return s, s != ""
}

// Localized enum/flags member label, keyed on the type name; ok=false if none.
entity_flag_item_label :: proc(enum_type: string, member: string) -> (string, bool) {
    l: [Lang]string
    switch enum_type {
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
    case "EntityBasicStaticFlag":
        switch member {
        case "Static": l = {.EN = "Static", .ZH = "静态"}
        case "Renderable": l = {.EN = "Renderable", .ZH = "可渲染"}
        }
    case "EntityBasicFlag":
        switch member {
        case "Enabled": l = {.EN = "Enabled", .ZH = "启用"}
        case "Hidden": l = {.EN = "Hidden", .ZH = "隐藏"}
        }
    }
    s := l[loc_lang]
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

