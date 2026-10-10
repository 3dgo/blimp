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
    // Model tint or light colour, stored linear; the picker shows and edits it as sRGB (like
    // Unity's).
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
    // A box in the level that game code asks about, flat on the entity like camera_type and
    // light_type: its box is size, centred on the entity and turned with it (scale doesn't apply).
    // Trigger: Lua asks Entity.contains(volume, point) each update; nothing fires by itself.
    volume_type: EntityVolumeType `section:Dimensions`,
    // The box the entity's projection or volume covers. Orthographic camera: y = view height (the
    // width comes from the target's aspect). Directional light: x, y = shadow area, z = its depth.
    // Volume: the whole box, centred on the entity. Later: fog and other volumes.
    size: vec3 `section:Dimensions`,
    // Near, far. Camera: clip planes. Point / spot / cylinder light: inner, outer distance of its
    // falloff — zero at y. Linear and Smooth are full intensity inside x. Inverse Square is
    // intensity / d² (intensity is the light at 1 unit), held flat inside x (the source's radius)
    // and windowed to zero at y. A cylinder's distance is along its beam, from its disc.
    range: vec2 `section:Dimensions`,
    shadow: bool `section:Camera_Light`,
    // The near plane of a point / spot light's shadow cameras (at least SHADOW_NEAR), where a
    // cylinder's shadow box starts along its beam, and how far short of the light the bake's shadow
    // rays stop. A point light's six near planes cut out a cube of this half-size; the bake's rays a
    // sphere. For a light inside its fixture: past the shade, the fixture stops shadowing its own
    // light without excluding it from any other light's shadows (no light linking).
    shadow_cull_near: f32 `section:Camera_Light`,
    // Which light group the light belongs to (World Settings → Light Groups): 0 = static, always
    // on; 1–4 can be dimmed or switched off at runtime (Lua World.set_light_group), realtime and
    // baked light together. On a model, the group its emissive follows the same way (lamp glass with
    // its lamp).
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
    // in the DCC (Play warns when the model has none). Render Mesh (the default): the model's own
    // triangles, every one of them. Static entities are static bodies; anything else follows its
    // entity every frame (kinematic), so a gate a script moves still blocks. Needs a model.
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

EntityVolumeType :: enum u64 {
    None,
    Trigger,
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
    e.volume_type = .None
    e.size = {10, 10, 50}
    e.range = {0.1, 20}
    e.shadow = false
    e.shadow_cull_near = 0.05
    e.light_group = 0
    e.indirect = 1
    e.halo = 1
    e.volume = 1
    e.sound_flags = {.Positional}
    e.collision = .Render_Mesh
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
    case "volume_type": l = {.EN = "Volume", .ZH = "体积"}
    case "size": l = {.EN = "Size", .ZH = "尺寸"}
    case "range": l = {.EN = "Range", .ZH = "范围"}
    case "shadow": l = {.EN = "Cast Shadow", .ZH = "投射阴影"}
    case "shadow_cull_near": l = {.EN = "Shadow Cull Near", .ZH = "阴影近处剔除"}
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

// A field's tooltip in every language (empty where it has none); see entity_tip_next.
entity_field_tips :: proc(name: string) -> (l: [Lang]string) {
    switch name {
    case "icon": l = {.EN = "Editor icon in the entity lists: a Material Symbols codepoint in hex (e.g. E835). Empty: a light or camera shows its type's icon, anything else none.", .ZH = "实体列表中的编辑器图标：Material Symbols 字形的十六进制码位（如 E835）。留空：灯光或相机显示其类型的图标，其他实体不显示。"}
    case "basic_static_flags": l = {.EN = "What the entity is in the static world: whether it moves, draws and bakes.", .ZH = "实体在静态世界中的角色：是否移动、绘制和参与烘焙。"}
    case "basic_flags": l = {.EN = "Whether the game and the editor see the entity.", .ZH = "游戏和编辑器是否处理该实体。"}
    case "model": l = {.EN = "The model the entity draws and collides as.", .ZH = "实体绘制和碰撞所用的模型。"}
    case "camera_type": l = {.EN = "Makes the entity a camera. A camera and a light are two entities.", .ZH = "使实体成为相机。相机和灯光需分为两个实体。"}
    case "light_type": l = {.EN = "Makes the entity a light. A camera and a light are two entities.", .ZH = "使实体成为灯光。相机和灯光需分为两个实体。"}
    case "color": l = {.EN = "Stored linear; the picker shows and edits it as sRGB.", .ZH = "以线性值存储；取色器以 sRGB 显示和编辑。"}
    case "fov": l = {.EN = "Degrees.", .ZH = "单位为度。"}
    case "inner_fov": l = {.EN = "Degrees.", .ZH = "单位为度。"}
    case "volume_type": l = {.EN = "Makes the entity a box that game code asks about (Entity.contains), like a trigger.", .ZH = "使实体成为一个供游戏代码查询的盒子（实体.包含），如触发区。"}
    case "range": l = {.EN = "Near, far (x, y).", .ZH = "近、远（x、y）。"}
    case "shadow_cull_near": l = {.EN = "Anything closer to the light than this casts no shadow from it, like the shade around a lamp's bulb. Other lights still see it as a caster.", .ZH = "离灯光比这更近的物体不会挡住这盏灯的光，比如灯泡周围的灯罩。其他灯光仍然会被它遮挡。"}
    case "sound": l = {.EN = "A sound file (.wav .ogg .mp3 .flac under assets/). It plays in play mode, on start with Play On Start or when Lua calls Entity.play_sound, and follows the entity.", .ZH = "声音文件（assets/ 下的 .wav .ogg .mp3 .flac）。在游戏模式中播放：勾选开始时播放则在开始时播放，或由 Lua 调用 Entity.play_sound；播放时跟随实体。"}
    case "velocity": l = {.EN = "Metres per second, for game code: Lua reads and writes it. Nothing in the engine moves an entity by it.", .ZH = "米/秒，供游戏代码使用：由 Lua 读写。引擎本身不会用它移动实体。"}
    }
    return
}

// A field's tooltip for the current language, else the other one's ("" if none).
entity_field_tip :: proc(name: string) -> string {
    l := entity_field_tips(name)
    for s in ([]string{l[loc_lang], l[.EN], l[.ZH]}) do if s != "" do return s
    return ""
}

@(private = "file")
_uses_model := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return e.model != "" },
        fields = {"model"},
        cond   = "model",
        text   = {.EN = "Drawn, and with Collision, collided as in play mode.", .ZH = "会被绘制；设置了碰撞时，在游戏模式中参与碰撞。"},
    },
}

@(private = "file")
_uses_anim := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return e.model != "" },
        fields = {"model"},
        cond   = "model",
        text   = {.EN = "A clip of the model's skeleton (its short name, e.g. Walk), looped in play mode while the script outputs no pose. Empty: the rest pose.", .ZH = "模型骨骼的动画片段（短名，如 Walk），在游戏模式下脚本未输出姿势时循环播放。留空：静止姿势。"},
    },
}

@(private = "file")
_uses_shading := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return e.model != "" },
        fields = {"model"},
        cond   = "model",
        text   = {.EN = "How the model's surfaces take light. Default: the level's (World Settings > Shading).", .ZH = "模型表面的受光方式。默认：使用关卡设置（世界设置 > 着色）。"},
    },
}

@(private = "file")
_uses_blend := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return e.model != "" },
        fields = {"model"},
        cond   = "model",
        text   = {.EN = "How the model's pixels combine with what's behind them. Alpha and Additive don't write depth or cast shadows, and draw after everything opaque.", .ZH = "模型像素与其背后内容的混合方式。Alpha 与叠加不写入深度、不投射阴影，并在所有不透明物体之后绘制。"},
    },
}

@(private = "file")
_uses_camera_type := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return u64(e.camera_type) != 0 },
        fields = {"camera_type"},
        cond   = "camera_type",
        text   = {.EN = "A camera: renders the view from its position, looking down its +Z.", .ZH = "相机：从其位置沿 +Z 方向渲染视图。"},
    },
}

@(private = "file")
_uses_light_type := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return u64(e.light_type) != 0 },
        fields = {"light_type"},
        cond   = "light_type",
        text   = {.EN = "A light: lights the scene, live and in the probe bake.", .ZH = "灯光：照亮场景，包括实时光照与探针烘焙。"},
    },
}

@(private = "file")
_uses_color := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return e.model != "" },
        fields = {"model"},
        cond   = "model",
        text   = {.EN = "Tint: multiplies the model's colour and its glow (emissive), scaled by Intensity.", .ZH = "色调：乘到模型颜色和它的自发光上，并按强度缩放。"},
    },
    {
        holds  = proc(e: ^Entity) -> bool { return u64(e.light_type) != 0 },
        fields = {"light_type"},
        cond   = "light_type",
        text   = {.EN = "The light's colour.", .ZH = "灯光的颜色。"},
    },
}

@(private = "file")
_uses_intensity := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return e.model != "" },
        fields = {"model"},
        cond   = "model",
        text   = {.EN = "Scales the tint: Color x Intensity (white x 1 = as authored).", .ZH = "缩放色调：颜色 x 强度（白色 x 1 = 原样）。"},
    },
    {
        holds  = proc(e: ^Entity) -> bool { return u64(e.light_type) != 0 },
        fields = {"light_type"},
        cond   = "light_type",
        text   = {.EN = "Brightness. With Inverse Square falloff, the light at 1 unit away.", .ZH = "亮度。平方反比衰减时为 1 单位距离处的光照。"},
    },
}

@(private = "file")
_uses_fov := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return (e.camera_type == .Perspective) },
        fields = {"camera_type"},
        cond   = "camera_type=Perspective",
        text   = {.EN = "Vertical field of view.", .ZH = "垂直视野角。"},
    },
    {
        holds  = proc(e: ^Entity) -> bool { return (e.light_type == .Spot) },
        fields = {"light_type"},
        cond   = "light_type=Spot",
        text   = {.EN = "Cone angle, also its shadow frustum.", .ZH = "光锥角度，也是其阴影视锥。"},
    },
}

@(private = "file")
_uses_inner_fov := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return (e.light_type == .Spot) },
        fields = {"light_type"},
        cond   = "light_type=Spot",
        text   = {.EN = "Inner cone angle: full intensity inside it, fading to zero at FOV. Clamped to FOV.", .ZH = "内锥角：其内为全强度，向 FOV 渐变为零。不超过 FOV。"},
    },
}

@(private = "file")
_uses_radius := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return (e.light_type == .Cylinder) },
        fields = {"light_type"},
        cond   = "light_type=Cylinder",
        text   = {.EN = "Beam radius: parallel rays from a disc along the entity's +Z, fading to zero at the radius. Also the shadow's width.", .ZH = "光束半径：从圆盘沿实体 +Z 方向发出的平行光，在半径处衰减为零。也是阴影的宽度。"},
    },
}

@(private = "file")
_uses_inner_radius := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return (e.light_type == .Cylinder) },
        fields = {"light_type"},
        cond   = "light_type=Cylinder",
        text   = {.EN = "Full intensity inside it, fading to zero at Radius. Clamped to Radius.", .ZH = "其内为全强度，向半径处渐变为零。不超过半径。"},
    },
}

@(private = "file")
_uses_falloff := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return (e.light_type == .Point || e.light_type == .Spot || e.light_type == .Cylinder) },
        fields = {"light_type"},
        cond   = "light_type=Point|Spot|Cylinder",
        text   = {.EN = "How the light fades over Range.", .ZH = "灯光在范围内的衰减方式。"},
    },
}

@(private = "file")
_uses_volume_type := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return u64(e.volume_type) != 0 },
        fields = {"volume_type"},
        cond   = "volume_type",
        text   = {.EN = "A volume: the box Size covers, centred on the entity and turned with it.", .ZH = "体积：Size 覆盖的盒子，以实体为中心，随实体旋转。"},
    },
}

@(private = "file")
_uses_size := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return (e.camera_type == .Orthographic) },
        fields = {"camera_type"},
        cond   = "camera_type=Orthographic",
        text   = {.EN = "y = view height; the width comes from the target's aspect.", .ZH = "y = 视图高度；宽度由渲染目标的宽高比决定。"},
    },
    {
        holds  = proc(e: ^Entity) -> bool { return (e.light_type == .Directional) },
        fields = {"light_type"},
        cond   = "light_type=Directional",
        text   = {.EN = "x, y = shadow area, z = its depth.", .ZH = "x、y = 阴影区域，z = 阴影深度。"},
    },
    {
        holds  = proc(e: ^Entity) -> bool { return u64(e.volume_type) != 0 },
        fields = {"volume_type"},
        cond   = "volume_type",
        text   = {.EN = "The volume's box, centred on the entity.", .ZH = "体积的盒子，以实体为中心。"},
    },
}

@(private = "file")
_uses_range := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return u64(e.camera_type) != 0 },
        fields = {"camera_type"},
        cond   = "camera_type",
        text   = {.EN = "Clip planes.", .ZH = "裁剪面。"},
    },
    {
        holds  = proc(e: ^Entity) -> bool { return (e.light_type == .Point || e.light_type == .Spot || e.light_type == .Cylinder) },
        fields = {"light_type"},
        cond   = "light_type=Point|Spot|Cylinder",
        text   = {.EN = "Falloff: zero at y. Linear and Smooth are full inside x; Inverse Square is held flat inside x (the source's radius). A cylinder measures along its beam. y is also the shadow's far plane.", .ZH = "衰减：在 y 处为零。线性与平滑在 x 内为全强度；平方反比在 x 内保持不变（光源半径）。圆柱光沿光束方向计算距离。y 也是阴影的远平面。"},
    },
    {
        holds  = proc(e: ^Entity) -> bool { return e.sound != "" && card(e.sound_flags & {.Positional}) > 0 },
        fields = {"sound", "sound_flags"},
        cond   = "sound&sound_flags=Positional",
        text   = {.EN = "Full volume within x, fading linearly to silent at y.", .ZH = "x 内为全音量，到 y 线性衰减至静音。"},
    },
}

@(private = "file")
_uses_shadow := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return u64(e.light_type) != 0 },
        fields = {"light_type"},
        cond   = "light_type",
        text   = {.EN = "Casts shadows, in realtime and in the probe bake.", .ZH = "投射阴影，包括实时阴影与探针烘焙。"},
    },
}

@(private = "file")
_uses_shadow_cull_near := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return e.shadow && (e.light_type == .Point || e.light_type == .Spot || e.light_type == .Cylinder) },
        fields = {"shadow", "light_type"},
        cond   = "shadow&light_type=Point|Spot|Cylinder",
        text   = {.EN = "Metres from the light (a cylinder: along its beam from the disc) within which nothing casts its shadow, in realtime and in the bake.", .ZH = "离灯光多少米以内的物体不投射它的阴影（圆柱光沿光束从圆盘算起），实时阴影与烘焙都一样。"},
    },
}

@(private = "file")
_uses_light_group := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return u64(e.light_type) != 0 },
        fields = {"light_type"},
        cond   = "light_type",
        text   = {.EN = "Light group (World Settings > Light Groups): 0 = static, always on; 1-4 can be dimmed or switched off at runtime (Lua World.set_light_group).", .ZH = "所属光源组（世界设置 > 光源组）：0 = 静态，始终开启；1-4 可在运行时调暗或关闭（Lua World.set_light_group）。"},
    },
    {
        holds  = proc(e: ^Entity) -> bool { return e.model != "" },
        fields = {"model"},
        cond   = "model",
        text   = {.EN = "The group the model's glow (emissive) follows: dimmed, switched off and flickering with the group's lights, on screen and in the bake. 0 = always on.", .ZH = "模型自发光所跟随的光源组：随该组灯光一起调暗、关闭和闪烁，屏幕上与烘焙中都一样。0 = 始终开启。"},
    },
}

@(private = "file")
_uses_indirect := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return u64(e.light_type) != 0 && card(e.basic_static_flags & {.Static}) > 0 && card(e.basic_static_flags & {.Cast_Indirect}) > 0 },
        fields = {"light_type", "basic_static_flags"},
        cond   = "light_type&basic_static_flags=Static&basic_static_flags=Cast_Indirect",
        text   = {.EN = "Scales its baked bounce (the probes) without touching its direct light.", .ZH = "缩放其烘焙的反弹光（探针），不影响直接光。"},
    },
}

@(private = "file")
_uses_halo := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return (e.light_type == .Point || e.light_type == .Spot) },
        fields = {"light_type"},
        cond   = "light_type=Point|Spot",
        text   = {.EN = "Scales its glow in the fog (World Settings > Fog > Lamp Halos) without touching its light on surfaces. 0 = no halo.", .ZH = "缩放其在雾中的光晕（世界设置 > 雾 > 灯光光晕），不影响表面光照。0 = 无光晕。"},
    },
}

@(private = "file")
_uses_sound := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return e.sound != "" },
        fields = {"sound"},
        cond   = "sound",
        text   = {.EN = "Plays in play mode (Play On Start, or Lua Entity.play_sound) and follows the entity.", .ZH = "在游戏模式中播放（开始时播放，或由 Lua 调用 Entity.play_sound），并跟随实体。"},
    },
}

@(private = "file")
_uses_volume := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return e.sound != "" },
        fields = {"sound"},
        cond   = "sound",
        text   = {.EN = "Playback volume (1 = as recorded).", .ZH = "播放音量（1 = 原始音量）。"},
    },
}

@(private = "file")
_uses_sound_flags := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return e.sound != "" },
        fields = {"sound"},
        cond   = "sound",
        text   = {.EN = "How the sound plays.", .ZH = "声音的播放方式。"},
    },
}

@(private = "file")
_uses_collision := [?]Entity_Field_Use{
    {
        holds  = proc(e: ^Entity) -> bool { return e.model != "" },
        fields = {"model"},
        cond   = "model",
        text   = {.EN = "What it collides as in play mode. Static entities are static bodies; others follow the entity (kinematic).", .ZH = "游戏模式中的碰撞形状。静态实体为静态刚体；其他实体跟随实体移动（运动学）。"},
    },
}

// A field's `when` entries (none: it always does something).
entity_field_uses :: proc(name: string) -> []Entity_Field_Use {
    switch name {
    case "model": return _uses_model[:]
    case "anim": return _uses_anim[:]
    case "shading": return _uses_shading[:]
    case "blend": return _uses_blend[:]
    case "camera_type": return _uses_camera_type[:]
    case "light_type": return _uses_light_type[:]
    case "color": return _uses_color[:]
    case "intensity": return _uses_intensity[:]
    case "fov": return _uses_fov[:]
    case "inner_fov": return _uses_inner_fov[:]
    case "radius": return _uses_radius[:]
    case "inner_radius": return _uses_inner_radius[:]
    case "falloff": return _uses_falloff[:]
    case "volume_type": return _uses_volume_type[:]
    case "size": return _uses_size[:]
    case "range": return _uses_range[:]
    case "shadow": return _uses_shadow[:]
    case "shadow_cull_near": return _uses_shadow_cull_near[:]
    case "light_group": return _uses_light_group[:]
    case "indirect": return _uses_indirect[:]
    case "halo": return _uses_halo[:]
    case "sound": return _uses_sound[:]
    case "volume": return _uses_volume[:]
    case "sound_flags": return _uses_sound_flags[:]
    case "collision": return _uses_collision[:]
    }
    return nil
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
    case "EntityVolumeType":
        switch member {
        case "None": l = {.EN = "None", .ZH = "无"}
        case "Trigger": l = {.EN = "Trigger", .ZH = "触发区"}
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

// An enum/flags member's tooltip in every language, keyed on the type name (empty where it has none).
entity_member_tips :: proc(enum_type: string, member: string) -> (l: [Lang]string) {
    switch enum_type {
    case "EntityCollision":
        switch member {
        case "None": l = {.EN = "Doesn't collide.", .ZH = "不参与碰撞。"}
        case "Box": l = {.EN = "The model's bounding box: the cheapest.", .ZH = "模型的包围盒：开销最低。"}
        case "Collision_Mesh": l = {.EN = "The kit's <model>_col mesh, authored in the DCC. Play warns when the model has none.", .ZH = "套件中的 <model>_col 网格，在建模软件中制作。模型没有时，进入游戏会给出警告。"}
        case "Render_Mesh": l = {.EN = "Every triangle of the model itself: exact, and the most expensive.", .ZH = "模型自身的全部三角形：最精确，开销最高。"}
        }
    case "EntityCameraType":
        switch member {
        case "None": l = {.EN = "Not a camera.", .ZH = "不是相机。"}
        case "Perspective": l = {.EN = "Things shrink with distance. FOV is the vertical field of view; Range the clip planes.", .ZH = "近大远小。FOV 为垂直视野角；范围为裁剪面。"}
        case "Orthographic": l = {.EN = "No perspective: things keep their size at any distance. Size.y is the view height; Range the clip planes.", .ZH = "无透视：物体大小不随距离变化。Size.y 为视图高度；范围为裁剪面。"}
        }
    case "EntityLightType":
        switch member {
        case "None": l = {.EN = "Not a light.", .ZH = "不是灯光。"}
        case "Directional": l = {.EN = "Parallel light from far away, like the sun, along the entity's +Z. Lights everything; its shadow covers the box set by Size.", .ZH = "来自远处的平行光（如太阳），沿实体 +Z 方向。照亮所有物体；阴影覆盖 Size 设定的范围。"}
        case "Point": l = {.EN = "Shines in every direction from the entity, fading over Range.", .ZH = "从实体向所有方向发光，在范围内衰减。"}
        case "Spot": l = {.EN = "A cone along the entity's +Z: FOV wide, full inside Inner FOV, fading over Range.", .ZH = "沿实体 +Z 方向的光锥：宽度为 FOV，Inner FOV 内为全强度，在范围内衰减。"}
        case "Cylinder": l = {.EN = "A beam of parallel rays from a disc along the entity's +Z: Radius wide, full inside Inner Radius, fading over Range.", .ZH = "从圆盘沿实体 +Z 方向发出的平行光束：宽度为半径，内半径内为全强度，在范围内衰减。"}
        }
    case "EntityVolumeType":
        switch member {
        case "None": l = {.EN = "Not a volume.", .ZH = "不是体积。"}
        case "Trigger": l = {.EN = "A box game code checks things against: a script asks Entity.contains(volume, point) each update, to switch levels, open a door, start a sound.", .ZH = "供游戏代码检测的盒子：脚本每次更新用 实体.包含(体积, 点) 来问，用来切换关卡、开门、放声音。"}
        }
    case "EntityLightFalloff":
        switch member {
        case "Inverse_Square": l = {.EN = "Physical: intensity / d², windowed to zero at range.y. Intensity is the light at 1 unit away.", .ZH = "物理衰减：强度 / d²，在 range.y 处收为零。强度为 1 单位距离处的光照。"}
        case "Linear": l = {.EN = "Full inside range.x, falling in a straight line to zero at range.y.", .ZH = "range.x 内为全强度，到 range.y 线性降为零。"}
        case "Smooth": l = {.EN = "Full inside range.x, easing to zero at range.y: no visible edge at either end.", .ZH = "range.x 内为全强度，到 range.y 平滑降为零：两端都没有明显边缘。"}
        }
    case "ShadingModel":
        switch member {
        case "Unlit": l = {.EN = "Texture x colour, no light.", .ZH = "贴图 x 颜色，不受光照。"}
        case "Gouraud": l = {.EN = "Lit per vertex and blended across the face, diffuse only: the PS1 look. Shadows are per pixel.", .ZH = "逐顶点光照并在面上插值，仅漫反射：PS1 的效果。阴影为逐像素。"}
        case "Lambert": l = {.EN = "Lit per pixel with the mesh's smooth normals, diffuse only: Gouraud without the vertex artifacts.", .ZH = "使用网格平滑法线逐像素光照，仅漫反射：没有顶点瑕疵的 Gouraud。"}
        case "Flat": l = {.EN = "Lit per pixel with each face's own normal, diffuse only: faceted.", .ZH = "使用每个面自身的法线逐像素光照，仅漫反射：呈多面体感。"}
        case "Phong": l = {.EN = "Lit per pixel, with a specular highlight.", .ZH = "逐像素光照，带高光。"}
        }
    case "EntityShading":
        switch member {
        case "Default": l = {.EN = "The level's shading (World Settings > Shading).", .ZH = "使用关卡的着色（世界设置 > 着色）。"}
        case "Unlit": l = {.EN = "Texture x colour, no light.", .ZH = "贴图 x 颜色，不受光照。"}
        case "Gouraud": l = {.EN = "Lit per vertex and blended across the face, diffuse only: the PS1 look. Shadows are per pixel.", .ZH = "逐顶点光照并在面上插值，仅漫反射：PS1 的效果。阴影为逐像素。"}
        case "Lambert": l = {.EN = "Lit per pixel with the mesh's smooth normals, diffuse only: Gouraud without the vertex artifacts.", .ZH = "使用网格平滑法线逐像素光照，仅漫反射：没有顶点瑕疵的 Gouraud。"}
        case "Flat": l = {.EN = "Lit per pixel with each face's own normal, diffuse only: faceted.", .ZH = "使用每个面自身的法线逐像素光照，仅漫反射：呈多面体感。"}
        case "Phong": l = {.EN = "Lit per pixel, with a specular highlight.", .ZH = "逐像素光照，带高光。"}
        }
    case "EntityBlend":
        switch member {
        case "Opaque": l = {.EN = "Solid: hides what's behind it.", .ZH = "不透明：遮挡其后的物体。"}
        case "Cutout": l = {.EN = "Solid, but pixels under half alpha are cut out (fences, foliage). Shadows still see the whole quad.", .ZH = "不透明，但 alpha 低于一半的像素会被裁掉（栅栏、植被）。阴影仍按整个面片投射。"}
        case "Alpha": l = {.EN = "See-through by the texture's alpha. Doesn't write depth or cast shadows; drawn after everything opaque, unsorted.", .ZH = "按贴图 alpha 半透明。不写入深度、不投射阴影；在所有不透明物体之后绘制，不排序。"}
        case "Additive": l = {.EN = "Adds its colour to what's behind it (glows, fire). Doesn't write depth or cast shadows; drawn after everything opaque.", .ZH = "将颜色叠加到其后的内容上（光晕、火焰）。不写入深度、不投射阴影；在所有不透明物体之后绘制。"}
        }
    case "EntityBasicStaticFlag":
        switch member {
        case "Static": l = {.EN = "Never moves: a static physics body, and it can take part in the probe bake. Off: its body follows the entity (kinematic).", .ZH = "不会移动：静态物理刚体，并可参与探针烘焙。关闭时：其刚体跟随实体移动（运动学）。"}
        case "Renderable": l = {.EN = "Drawn, and pickable in the viewport. A light shines only while this is on.", .ZH = "会被绘制，并可在视口中点选。灯光只有开启此项时才会发光。"}
        case "Cast_Indirect": l = {.EN = "With Static: blocks and bounces light in the probe bake. Off for clutter that would only add noise.", .ZH = "与静态一起：在探针烘焙中遮挡并反弹光线。对只会增加噪点的杂物请关闭。"}
        }
    case "EntityBasicFlag":
        switch member {
        case "Enabled": l = {.EN = "Off: nothing sees the entity. It isn't drawn, doesn't collide, play sound or animate, and can't be the game camera.", .ZH = "关闭时：所有系统都忽略该实体。不绘制、不碰撞、不播放声音、不播放动画，也不能作为游戏相机。"}
        case "Hidden": l = {.EN = "Not drawn (in the editor and in game) and not pickable; physics and sound still run. Lua can toggle it.", .ZH = "不绘制（编辑器与游戏中均是）且无法点选；物理和声音仍然生效。Lua 可切换此项。"}
        }
    case "EntitySoundFlag":
        switch member {
        case "Play_On_Start": l = {.EN = "Plays when the game starts.", .ZH = "游戏开始时播放。"}
        case "Loop": l = {.EN = "Repeats until stopped.", .ZH = "循环播放直到停止。"}
        case "Positional": l = {.EN = "Fades with distance over Range: full within range.x, silent at range.y. Off: the same everywhere (music, UI).", .ZH = "在范围内随距离衰减：range.x 内全音量，range.y 处静音。关闭时：处处音量相同（音乐、界面）。"}
        }
    }
    return
}

// A member's tooltip for the current language, else the other one's ("" if none).
entity_member_tip :: proc(enum_type: string, member: string) -> string {
    l := entity_member_tips(enum_type, member)
    for s in ([]string{l[loc_lang], l[.EN], l[.ZH]}) do if s != "" do return s
    return ""
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

