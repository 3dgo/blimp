package blimp

import "core:log"

// UI localization: English + Simplified Chinese, primary user is zh.
//
// Strings are static `cstring`s so ImGui consumes them with no per-frame allocation.
// The table is an enumerated array (dense enum -> direct index), not a map: O(1),
// zero-alloc, lives in rodata, and both languages sit on one row so they can't drift.
// `loc_verify` (called at UI init) fails loudly if any cell was left unfilled.
//
// Scope: user-facing UI labels only. Logs, asserts, asset keys and file paths stay
// ASCII English — they are developer diagnostics, and keys must stay portable.
//
// Window titles embed a stable `###id` suffix: ImGui derives a window's identity from
// its label, so without it a language switch would give windows new ids and reset the
// docking layout. Triple-hash `###` makes the id come *only* from the suffix (double
// `##` would still hash the visible half, so it must be `###`). Visible half translates;
// the id half never changes.
//
// This table is for fixed engine UI (menus, window titles). Entity field/flag labels are baked
// from entity_schema.ini into gen_entity.odin by codegen (entity_field_label etc.), not entries
// here. The reflection inspector still honors a `loc:<Loc_ID>` field tag as a fallback for any
// hand-authored struct that isn't schema-backed.

Lang :: enum { EN, ZH }
loc_lang: Lang = .ZH   // default to the primary (Simplified Chinese) user

Loc_ID :: enum {
    // Windows (visible###stable-id)
    Win_Schema_Editor,
    Win_Worlds,
    // Main menu
    Menu_Show,
    Menu_Entity_List,
    Menu_Entity_Inspector,
    Menu_Schema_Editor,
    Menu_Worlds,
    Menu_Language,
    Menu_Section_Entities,
    Menu_Section_Project,
    Menu_Section_Profile,
    // Worlds window
    Worlds_Open,
    Worlds_Scenes,
    Worlds_Kits,
    Worlds_None,
    Worlds_Subtitle,
    Worlds_Search,
    Worlds_Opened_Tag,
    Worlds_Kit_Tag,
    Btn_New_Viewport,
    Btn_Close,
    Btn_Refresh,
    View_Suffix,
    // Schema editor
    Schema_Save,
    Schema_Reload,
    Schema_Apply,
    Schema_Fields,
    Schema_Types,
    Schema_Add_Field,
    Schema_Add_Type,
    Schema_Rename_Hint,
    Schema_Prop_Id,
    Schema_Prop_Type,
    Schema_Prop_English,
    Schema_Prop_Chinese,
    Schema_Prop_Default,
    Schema_Prop_Name,
    Schema_Kind,
    Schema_Kind_Enum,
    Schema_Kind_Flags,
    Schema_Kind_Struct,
    Schema_Members,
    Schema_Move_Up,
    Schema_Move_Down,
    Schema_Remove,
    Schema_Add_Member,
    Schema_Remove_Type,
    Schema_Builtin,
    Schema_Status_Saved,
    Schema_Status_Reloaded,
    Schema_Status_Build_Failed,

    Btn_Paste_Over,
    Btn_Paste,
    Btn_Save_Level,
    Tool_Select,
    Tool_Move,
    Tool_Rotate,
    Tool_Scale,
    Tool_Snap,
    Tool_Snap_Tip,
    Tool_Space_Global,
    Tool_Space_Local,
    Tool_Space_Tip,
    Tool_Pivot_Center,
    Tool_Pivot_Individual,
    Tool_Pivot_Tip,
    Save_No_Changes,
    Unsaved_Title,
    Unsaved_World_Msg,
    Unsaved_Quit_Msg,
    Btn_Save_Changes,
    Btn_Save_All,
    Btn_Dont_Save,
    Btn_Cancel,
    Inspector_Multi,
    Win_World_Settings,
    World_Background,
    World_Script,
    Win_Game_Settings,
    Menu_Game_Settings,
    Game_Start_Level,
    // Entity panels
    Panel_Follow,
    Inspector_Kit_Warning,
    Panel_No_World,
    // Asset Buffers window
    Win_Asset_Buffers,
    Menu_Asset_Buffers,
    Asset_Kind_Texture,
    Asset_Kind_Geometry,
    Asset_Kind_Table,
    Asset_Count,
    Asset_Shared,
    Asset_Mesh_Detail,
    Asset_Mesh_Table,
    Asset_Material_Table,
    // Entity right-click menu
    Ctx_Copy,
    Ctx_Paste,
    Ctx_Duplicate,
    Ctx_Delete,
    Ctx_Select_All,
    Ctx_Deselect,
    Ctx_Frame,
    Ctx_Hide,
    Ctx_Unhide_All,
    // Play mode
    Play_Play,
    Play_Stop,
    Play_Pause,
    Play_No_Save,
    Play_Warning,
    Worlds_Playing_Tag,
    Ctx_Rename,
    Tool_Maximize,
    Play_Step,
    Tool_Game_View,
}

@(rodata)
loc_text := [Loc_ID][Lang]cstring {
    .Win_Schema_Editor     = { .EN = "Schema Editor###schema_editor",       .ZH = "结构编辑器###schema_editor" },
    .Win_Worlds            = { .EN = "Worlds###worlds",                     .ZH = "世界###worlds" },

    .Menu_Show             = { .EN = "Show",             .ZH = "显示" },
    .Menu_Entity_List      = { .EN = "Entity List",      .ZH = "实体列表" },
    .Menu_Entity_Inspector = { .EN = "Entity Inspector", .ZH = "实体检查器" },
    .Menu_Schema_Editor    = { .EN = "Schema Editor",    .ZH = "结构编辑器" },
    .Menu_Worlds           = { .EN = "Worlds",           .ZH = "世界" },
    .Menu_Language         = { .EN = "Language",         .ZH = "语言" },
    .Menu_Section_Entities = { .EN = "ENTITIES",         .ZH = "实体" },
    .Menu_Section_Project  = { .EN = "PROJECT",          .ZH = "项目" },
    .Menu_Section_Profile  = { .EN = "PROFILE",          .ZH = "性能分析" },

    .Worlds_Open      = { .EN = "Open Worlds",   .ZH = "已打开的世界" },
    .Worlds_Scenes    = { .EN = "Scenes",        .ZH = "场景" },
    .Worlds_Kits      = { .EN = "Kits (glTF)",   .ZH = "套件 (glTF)" },
    .Worlds_None      = { .EN = "(none found)",  .ZH = "（未找到）" },
    .Worlds_Subtitle   = { .EN = "Open a scene to edit, or a kit to browse and copy models from.", .ZH = "打开场景进行编辑，或打开套件浏览并复制模型。" },
    .Worlds_Search     = { .EN = "Search scenes and kits", .ZH = "搜索场景和套件" },
    .Worlds_Opened_Tag = { .EN = "open",   .ZH = "已打开" },
    .Worlds_Kit_Tag    = { .EN = "kit", .ZH = "套件" },   // open-worlds panel: this world is a kit (not saved)
    .Btn_New_Viewport = { .EN = "New Viewport",  .ZH = "新视口" },
    .Btn_Close        = { .EN = "Close",         .ZH = "关闭" },
    .Btn_Refresh      = { .EN = "Refresh",       .ZH = "刷新" },
    .View_Suffix      = { .EN = "Viewport",      .ZH = "视口" },   // "<world title> 视口" on every view window

    .Schema_Save      = { .EN = "Save",            .ZH = "保存" },
    .Schema_Reload    = { .EN = "Reload",          .ZH = "重新加载" },
    .Schema_Apply     = { .EN = "Apply & Restart", .ZH = "应用并重启" },
    .Schema_Fields    = { .EN = "Fields",          .ZH = "字段" },
    .Schema_Types     = { .EN = "Types",           .ZH = "类型" },
    .Schema_Add_Field = { .EN = "Add Field",       .ZH = "添加字段" },
    .Schema_Add_Type  = { .EN = "Add Type",        .ZH = "添加类型" },

    .Schema_Rename_Hint  = { .EN = "Renaming a field id orphans that field's data in existing scenes.",
                             .ZH = "重命名字段 ID 会使现有场景中该字段的数据失效。" },
    .Schema_Prop_Id      = { .EN = "ID",       .ZH = "ID" },
    .Schema_Prop_Type    = { .EN = "Type",     .ZH = "类型" },
    .Schema_Prop_English = { .EN = "English",  .ZH = "英文" },
    .Schema_Prop_Chinese = { .EN = "Chinese",  .ZH = "中文" },
    .Schema_Prop_Default = { .EN = "Default",  .ZH = "默认值" },
    .Schema_Prop_Name    = { .EN = "Name",     .ZH = "名称" },
    .Schema_Kind         = { .EN = "Kind",     .ZH = "种类" },
    .Schema_Kind_Enum    = { .EN = "Enum",           .ZH = "枚举" },
    .Schema_Kind_Flags   = { .EN = "Bit set (flags)", .ZH = "位集合（标志）" },
    .Schema_Kind_Struct  = { .EN = "Struct",         .ZH = "结构体" },
    .Schema_Members      = { .EN = "Members",  .ZH = "成员" },
    .Schema_Move_Up      = { .EN = "Up",       .ZH = "上移" },
    .Schema_Move_Down    = { .EN = "Down",     .ZH = "下移" },
    .Schema_Remove       = { .EN = "Remove",   .ZH = "删除" },
    .Schema_Add_Member   = { .EN = "Add Member",  .ZH = "添加成员" },
    .Schema_Remove_Type  = { .EN = "Remove Type", .ZH = "删除类型" },
    .Schema_Builtin      = { .EN = "built-in", .ZH = "内置" },

    .Schema_Status_Saved        = { .EN = "Saved.",                      .ZH = "已保存。" },
    .Schema_Status_Reloaded     = { .EN = "Reloaded from disk.",         .ZH = "已从磁盘重新加载。" },
    .Schema_Status_Build_Failed = { .EN = "Build failed — see console.", .ZH = "编译失败 — 请查看控制台。" },

    .Btn_Paste_Over = { .EN = "Paste Over", .ZH = "覆盖粘贴" },
    .Btn_Paste      = { .EN = "Paste",      .ZH = "粘贴" },   // paste one field from the clipboard
    .Btn_Save_Level = { .EN = "Save",       .ZH = "保存" },   // viewport toolbar: write the world to its scene file
    .Tool_Select    = { .EN = "Select",     .ZH = "选择" },   // viewport toolbar tools
    .Tool_Move      = { .EN = "Move",       .ZH = "移动" },
    .Tool_Rotate    = { .EN = "Rotate",     .ZH = "旋转" },
    .Tool_Scale     = { .EN = "Scale",      .ZH = "缩放" },
    .Tool_Snap      = { .EN = "Snap",       .ZH = "吸附" },
    .Tool_Snap_Tip  = { .EN = "Hold Ctrl while dragging to invert", .ZH = "拖动时按住 Ctrl 临时反转" },
    .Tool_Space_Global = { .EN = "Global", .ZH = "全局" },
    .Tool_Space_Local  = { .EN = "Local",  .ZH = "局部" },
    .Tool_Space_Tip    = { .EN = "Move/rotate along world axes or the object's own (scale is always local)", .ZH = "移动/旋转沿世界坐标轴或物体自身坐标轴（缩放始终为局部）" },
    .Tool_Pivot_Center     = { .EN = "Center", .ZH = "中心" },
    .Tool_Pivot_Individual = { .EN = "Pivots", .ZH = "各自" },
    .Tool_Pivot_Tip        = { .EN = "Rotate/scale a multi-selection as one group about its centre, or each object about its own pivot", .ZH = "旋转/缩放多个对象时：整体绕选择中心，或各自绕自身轴心" },
    .Save_No_Changes   = { .EN = "No unsaved changes", .ZH = "没有未保存的更改" },
    .Unsaved_Title     = { .EN = "Unsaved Changes",    .ZH = "未保存的更改" },
    .Unsaved_World_Msg = { .EN = "has unsaved changes.", .ZH = "有未保存的更改。" },   // after the scene name
    .Unsaved_Quit_Msg  = { .EN = "These scenes have unsaved changes:", .ZH = "以下场景有未保存的更改：" },
    .Btn_Save_Changes  = { .EN = "Save",       .ZH = "保存" },
    .Btn_Save_All      = { .EN = "Save All",   .ZH = "全部保存" },
    .Btn_Dont_Save     = { .EN = "Don't Save", .ZH = "不保存" },
    .Btn_Cancel        = { .EN = "Cancel",     .ZH = "取消" },
    .Inspector_Multi   = { .EN = "%d selected (showing the active one)", .ZH = "已选择 %d 个（显示当前活动对象）" },
    .Win_World_Settings = { .EN = "World Settings", .ZH = "世界设置" },
    .World_Background   = { .EN = "Background",     .ZH = "背景色" },
    .World_Script       = { .EN = "Lua Script",     .ZH = "Lua 脚本" },
    .Win_Game_Settings  = { .EN = "Game Settings###game_settings", .ZH = "游戏设置###game_settings" },
    .Menu_Game_Settings = { .EN = "Game Settings",  .ZH = "游戏设置" },
    .Game_Start_Level   = { .EN = "Start Level",    .ZH = "起始关卡" },

    .Panel_Follow              = { .EN = "Follow active",        .ZH = "跟随活动视口" },
    .Panel_No_World            = { .EN = "No world open — open a scene or kit from the Worlds window.",
                                   .ZH = "没有打开的世界 — 请在“世界”窗口中打开场景或套件。" },
    .Inspector_Kit_Warning     = { .EN = "Opened from a kit — changes won't be saved.",
                                   .ZH = "从套件打开 — 更改不会被保存。" },

    .Win_Asset_Buffers    = { .EN = "Asset Buffers###asset_buffers", .ZH = "资源缓冲区###asset_buffers" },
    .Menu_Asset_Buffers   = { .EN = "Asset Buffers",  .ZH = "资源缓冲区" },
    .Asset_Kind_Texture   = { .EN = "Textures",       .ZH = "纹理" },
    .Asset_Kind_Geometry  = { .EN = "Geometry",       .ZH = "几何体" },
    .Asset_Kind_Table     = { .EN = "Tables",         .ZH = "数据表" },
    .Asset_Count          = { .EN = "%d assets",      .ZH = "%d 个资源" },
    .Asset_Shared         = { .EN = "shared by %d keys", .ZH = "被 %d 个键共享" },
    .Asset_Mesh_Detail    = { .EN = "%d vertices, %d triangles", .ZH = "%d 个顶点，%d 个三角形" },
    .Asset_Mesh_Table     = { .EN = "Mesh table",     .ZH = "网格表" },
    .Asset_Material_Table = { .EN = "Material table", .ZH = "材质表" },

    .Ctx_Copy       = { .EN = "Copy",            .ZH = "复制" },
    .Ctx_Paste      = { .EN = "Paste",           .ZH = "粘贴" },
    .Ctx_Duplicate  = { .EN = "Duplicate",       .ZH = "创建副本" },
    .Ctx_Delete     = { .EN = "Delete",          .ZH = "删除" },
    .Ctx_Select_All = { .EN = "Select All",      .ZH = "全选" },
    .Ctx_Deselect   = { .EN = "Deselect",        .ZH = "取消选择" },
    .Ctx_Frame      = { .EN = "Frame Selection", .ZH = "聚焦所选" },
    .Ctx_Hide       = { .EN = "Hide",            .ZH = "隐藏" },
    .Ctx_Unhide_All = { .EN = "Unhide All",      .ZH = "全部取消隐藏" },

    .Play_Play          = { .EN = "Play",    .ZH = "运行" },
    .Play_Stop          = { .EN = "Stop",    .ZH = "停止" },
    .Play_Pause         = { .EN = "Pause",   .ZH = "暂停" },
    .Play_No_Save       = { .EN = "Can't save while playing — stop first.", .ZH = "运行中无法保存 — 请先停止。" },
    .Play_Warning       = { .EN = "Playing — changes are discarded on Stop.", .ZH = "运行中 — 停止后更改将被丢弃。" },
    .Worlds_Playing_Tag = { .EN = "playing", .ZH = "运行中" },
    .Ctx_Rename         = { .EN = "Rename",   .ZH = "重命名" },
    .Tool_Maximize      = { .EN = "Maximize", .ZH = "最大化" },
    .Play_Step          = { .EN = "Step one frame", .ZH = "单步一帧" },
    .Tool_Game_View     = { .EN = "Game View: hide icons, outlines and the gizmo", .ZH = "游戏视图：隐藏图标、轮廓和操纵器" },
}

// Localized label for the current language, ready to hand straight to ImGui.
tr :: proc(id: Loc_ID) -> cstring {
    return loc_text[id][loc_lang]
}

// Same, as an Odin string — for composing into fmt.*printf.
trs :: proc(id: Loc_ID) -> string {
    return string(loc_text[id][loc_lang])
}

// Fail loudly at startup on a half-translated key (an unfilled cell is a nil cstring).
loc_verify :: proc() {
    for row, id in loc_text {
        for s, lang in row {
            if s == nil || s == "" {
                log.panicf("Missing localization: %v / %v", id, lang)
            }
        }
    }
}
