-- Blimp Clips: cut a character's one timeline into named clips and mark events on it, for the engine.
--
-- 3ds Max has one timeline per scene, so every action of a character goes on it one after another. Both clips
-- and events are Max time tags, so they show on the time slider:
--   - a clip is a tag named "▶Walk" at its first frame; it runs to the frame before the next ▶ tag (the last one
--     to the end of the timeline). Splitting at the slider adds one; there are no end frames to keep in step.
--     Frames before the first ▶ tag are an unnamed clip, which isn't saved until it's given a name.
--   - an event is any other tag ("footstep"), belonging to the clip it falls in.
-- While the dialog is open, the viewports show the clip and frame under the slider, and any event on it; in the
-- dialog's lists, ● marks the same clip and events.
-- Every change writes <scene>.clips next to the .max, as does saving the .max; the glTF export goes there too
-- (knight.max -> knight.gltf + knight.clips). The file keeps explicit ranges ([Walk 40 64]); the engine cuts the
-- exported animation by it at import (claude/animation.md -> Clips file). A scene with no tags yet gets them
-- from an existing .clips when the dialog opens.
--
-- Install: run tools\max\install.bat (a loader in each Max version's user startup folder that fileIns this file, so
-- edits here apply on the next Max start), or copy this file into a scripts\startup folder. Then restart Max. It adds
-- a Blimp menu to the main menu bar with Blimp Clips in it (also an action under Customize User Interface, category
-- Blimp), and doesn't open by itself at launch. Run by hand (Scripting > Run Script, or dropped on a viewport) it
-- opens the dialog.
-- Keep the timeline starting at frame 0: glTF time 0 is the first exported frame. For a looping clip, make its
-- last frame the same pose as its first.
--
-- Saved as UTF-8 with a BOM: the UI is Chinese, and without the BOM Max reads the file in the system code page.

global BlimpClips_Rollout
try (destroyDialog BlimpClips_Rollout) catch ()

global BlimpClips_Prefix = "▶"   -- marks a time tag as a clip start
global BlimpClips_FullRange       -- the timeline before Preview narrowed it; undefined when not previewing

-- A time tag's time. Tries GetTimeByID with the id alone, then with (id, relative): not verified which form
-- this Max version wants (CreateNewTag turned out to take just name and time). SetTimeByID likewise.
fn BlimpClips_TagTime id = (
    try (FrameTagManager.GetTimeByID id) catch (FrameTagManager.GetTimeByID id false)
)

fn BlimpClips_SetTagTime id t = (
    try (FrameTagManager.SetTimeByID id t) catch (FrameTagManager.SetTimeByID id t false)
)

fn BlimpClips_IsClipTag name = (
    name.count > 0 and name[1] == BlimpClips_Prefix
)

-- One word: the engine reads "name frame".
fn BlimpClips_CleanName s = (
    substituteString (trimLeft (trimRight s)) " " "_"
)

fn BlimpClips_CompareFrame a b = (
    if a[2] < b[2] then -1 else if a[2] > b[2] then 1 else 0
)

-- Every time tag as #(id, frame, name), by frame. Indices are tried from 0 and from 1, so this holds whichever way
-- the interface counts them.
fn BlimpClips_Tags = (
    local ids = #()
    for i = 0 to FrameTagManager.GetTagCount() do (
        local id = try (FrameTagManager.GetTagID i) catch undefined
        if id != undefined and id != 0 and findItem ids id == 0 do append ids id
    )
    local tags = for id in ids collect #(id, (BlimpClips_TagTime id).frame, FrameTagManager.GetNameByID id)
    qsort tags BlimpClips_CompareFrame
    tags
)

-- The whole timeline, even while Preview has narrowed it.
fn BlimpClips_Range = (
    if BlimpClips_FullRange != undefined then BlimpClips_FullRange else animationRange
)

fn BlimpClips_StopPreview = (
    stopAnimation()
    if BlimpClips_FullRange != undefined do (
        animationRange = BlimpClips_FullRange
        BlimpClips_FullRange = undefined
    )
)

-- #(clips, events) from the tags. A clip is #(name, start, end, tag id); the unnamed one before the first ▶ tag has
-- name "" and id undefined. An event is #(tag id, frame, name, clip name), clip name "" when it's in no named clip.
fn BlimpClips_Read = (
    local range = BlimpClips_Range()
    local first = range.start.frame
    local last = range.end.frame
    local starts = #()
    local events = #()
    for t in BlimpClips_Tags() do (
        if BlimpClips_IsClipTag t[3] then append starts t else append events t
    )
    local clips = #()
    if starts.count == 0 or starts[1][2] > first do (
        append clips #("", first, (if starts.count == 0 then last else starts[1][2] - 1), undefined)
    )
    for i = 1 to starts.count do (
        local e = if i < starts.count then starts[i + 1][2] - 1 else last
        append clips #(substring starts[i][3] 2 -1, starts[i][2], e, starts[i][1])
    )
    for ev in events do (
        local owner = ""
        for c in clips where c[1] != "" and ev[2] >= c[2] and ev[2] <= c[3] do owner = c[1]
        append ev owner
    )
    #(clips, events)
)

-- While the dialog is open, every viewport shows where the slider is: its clip, the frame within it, and the
-- events on this frame. Max has no way to draw on the time slider itself, so this is the next best place.
fn BlimpClips_DrawOverlay = (
    local f = sliderTime.frame
    local data = BlimpClips_Read()
    local line = ""
    for c in data[1] where f >= c[2] and f <= c[3] do (
        line = (if c[1] == "" then "（未命名）" else c[1]) + "   " + ((f - c[2]) as integer) as string + " / " + ((c[3] - c[2]) as integer) as string
    )
    for ev in data[2] where abs (ev[2] - f) < 0.5 do line += "   ▸ " + ev[3]
    if line != "" do (
        gw.setTransform (matrix3 1)
        gw.wText [12, 40, 0] line color:(color 255 214 90)
        gw.enlargeUpdateRect #whole
        gw.updateScreen()
    )
)

-- Keeps the dialog's ● marks on the slider's clip and events.
fn BlimpClips_OnTime = (
    if BlimpClips_Rollout != undefined and BlimpClips_Rollout.open do BlimpClips_Rollout.fillLists()
)

fn BlimpClips_Path = (
    if maxFileName == "" then undefined else (maxFilePath + getFilenameFile maxFileName + ".clips")
)

-- Writes <scene>.clips from the tags (only once the scene has a named clip, so a hand-written file next to a
-- scene without tags is left alone). Returns what happened, for the dialog.
fn BlimpClips_Save = (
    local path = BlimpClips_Path()
    local data = BlimpClips_Read()
    local named = for c in data[1] where c[1] != "" collect c
    if path == undefined then (
        "先保存 .max 文件：.clips 文件写在它旁边。"
    ) else if named.count == 0 then (
        "还没有片段：在滑块处切分，或给整段起个名字。"
    ) else (
        local ss = stringStream ""
        format "# Clips and events for %.gltf, written by tools/max/blimp_clips.ms (claude/animation.md -> Clips file).\n" (getFilenameFile maxFileName) to:ss
        format "# [Clip start end] = timeline frames; event lines are frames on the same timeline (Max time tags).\n" to:ss
        format "fps %\n" frameRate to:ss
        local savedClips = 0
        local savedEvents = 0
        local problems = ""
        for c in named do (
            if c[3] <= c[2] then (
                problems += "\n片段 " + c[1] + " 不到两帧，没有保存（起点和下一段太近）。"
            ) else (
                savedClips += 1
                format "\n[% % %]\n" c[1] (c[2] as integer) (c[3] as integer) to:ss
                for ev in data[2] where ev[4] == c[1] do (
                    format "% %\n" (BlimpClips_CleanName ev[3]) ev[2] to:ss
                    savedEvents += 1
                )
            )
        )
        (dotNetClass "System.IO.File").WriteAllText path (ss as string) (dotNetObject "System.Text.UTF8Encoding" false)
        local msg = "已保存 " + filenameFromPath path + "：" + savedClips as string + " 个片段，" + savedEvents as string + " 个事件。"
        local lost = 0
        for ev in data[2] where ev[4] == "" do lost += 1
        if lost > 0 do msg += "\n" + lost as string + " 个事件不在有名字的片段里，没有保存。"
        if (BlimpClips_Range()).start.frame != 0 do msg += "\n时间轴不是从第 0 帧开始：导出的 glTF 从第一帧算起，片段会错位。"
        msg + problems
    )
)

-- A scene with no time tags yet gets them from its .clips file (clip starts as ▶ tags, events as tags). Returns
-- what happened, "" if nothing.
fn BlimpClips_LoadFile = (
    local path = BlimpClips_Path()
    if path == undefined or FrameTagManager.GetTagCount() > 0 or not doesFileExist path then "" else (
        local clipCount = 0
        local inClip = false
        for raw in (dotNetClass "System.IO.File").ReadAllLines path do (
            local l = raw
            local h = findString l "#"
            if h != undefined do l = substring l 1 (h - 1)
            l = trimLeft (trimRight l)
            if l != "" do (
                if l[1] == "[" and l[l.count] == "]" then (
                    local head = filterString (substring l 2 (l.count - 2)) " \t"
                    inClip = head.count == 3
                    if inClip do (
                        FrameTagManager.CreateNewTag (BlimpClips_Prefix + head[1]) ((head[2] as float) as time)
                        clipCount += 1
                    )
                ) else (
                    local tok = filterString l " \t"
                    if inClip and tok.count == 2 and tok[1] != "fps" do FrameTagManager.CreateNewTag tok[1] ((tok[2] as float) as time)
                )
            )
        )
        "从 " + filenameFromPath path + " 读入了 " + clipCount as string + " 个片段。"
    )
)

rollout BlimpClips_Rollout "Blimp 动画片段" width:360 height:650
(
    local clipRows = #()    -- BlimpClips_Read's clips, as listed
    local eventRows = #()   -- and its events

    group "片段：时间轴上 ▶ 标签开始的一段"
    (
        listbox lbClips "" height:7
        edittext etClipName "名称" fieldWidth:270
        edittext etNewName "新片段名" text:"Walk" fieldWidth:247
        button btnSplit "在滑块处切分" width:106 across:3
        button btnMoveStart "起点移到滑块" width:106
        button btnMerge "并入上一段" width:106
        button btnPreview "循环预览" width:160 across:2
        button btnFull "恢复完整时间轴" width:160
    )
    group "事件：时间轴上的其他标签"
    (
        listbox lbEvents "" height:7
        edittext etEvent "名称" text:"footstep" fieldWidth:270
        button btnEventAdd "在滑块处添加" width:106 across:3
        button btnEventDelete "删除" width:106
        button btnRefresh "刷新" width:106
    )
    label lbHelp "双击列表跳到那一帧。名称按回车生效。" align:#left
    label lbHelp2 "在时间轴上改了标签后点「刷新」。" align:#left
    edittext etStatus "" readOnly:true height:58 width:340 align:#left

    fn selectedClip = (
        if lbClips.selection == 0 then undefined else clipRows[lbClips.selection]
    )

    -- The list texts, with ● on the clip under the slider and on the events at its frame. Called again on every
    -- time change (BlimpClips_OnTime): a MAXScript listbox can't colour a row, so the mark is a symbol. Other rows
    -- get ○, not spaces: the list font is proportional, and ○ is the one thing as wide as ●.
    fn fillLists = (
        local f = sliderTime.frame
        local clipSel = lbClips.selection
        local eventSel = lbEvents.selection
        lbClips.items = for c in clipRows collect (
            (if f >= c[2] and f <= c[3] then "● " else "○ ") + \
            (if c[1] == "" then "（未命名，不保存）" else c[1]) + "    " + (c[2] as integer) as string + " - " + (c[3] as integer) as string
        )
        lbEvents.items = for e in eventRows collect (
            (if abs (e[2] - f) < 0.5 then "● " else "○ ") + \
            (e[2] as string) + "    " + e[3] + "    → " + (if e[4] == "" then "不在片段里" else e[4])
        )
        lbClips.selection = clipSel
        lbEvents.selection = eventSel
    )

    -- Re-reads the tags into both lists (keeping the selected clip by name), writes the .clips file, and shows what
    -- happened under `note`.
    fn refresh selectName:undefined note:"" = (
        if selectName == undefined do (
            local c = selectedClip()
            if c != undefined do selectName = c[1]
        )
        local data = BlimpClips_Read()
        clipRows = data[1]
        eventRows = data[2]
        fillLists()
        local sel = 0
        for i = 1 to clipRows.count where clipRows[i][1] == selectName do sel = i
        lbClips.selection = sel
        local c = selectedClip()
        etClipName.text = if c == undefined then "" else c[1]
        local msg = BlimpClips_Save()
        if note != "" do msg = note + "\n" + msg
        etStatus.text = substituteString msg "\n" "\r\n"
    )

    -- "" if `name` can be a clip's (other than the row `except`), else why not.
    fn nameProblem name except:0 = (
        local problem = ""
        if name == "" then problem = "名称不能是空的。"
        else if BlimpClips_IsClipTag name then problem = "名称不能以 ▶ 开头。"
        else for i = 1 to clipRows.count where i != except and clipRows[i][1] == name do problem = "已经有片段叫 " + name + "。"
        problem
    )

    on BlimpClips_Rollout open do (
        refresh note:(BlimpClips_LoadFile())
        unRegisterRedrawViewsCallback BlimpClips_DrawOverlay
        registerRedrawViewsCallback BlimpClips_DrawOverlay
        unRegisterTimeCallback BlimpClips_OnTime
        registerTimeCallback BlimpClips_OnTime
        redrawViews()
    )

    on BlimpClips_Rollout close do (
        BlimpClips_StopPreview()
        unRegisterRedrawViewsCallback BlimpClips_DrawOverlay
        unRegisterTimeCallback BlimpClips_OnTime
        redrawViews()
    )

    on lbClips selected i do etClipName.text = clipRows[i][1]

    -- Jumping leaves a preview first: its narrowed timeline would clamp the slider into the previewed clip.
    on lbClips doubleClicked i do (
        BlimpClips_StopPreview()
        sliderTime = clipRows[i][2]
    )

    -- Renames the selected clip; naming the unnamed one puts its ▶ tag at the start of the timeline.
    on etClipName entered txt do (
        local c = selectedClip()
        if c == undefined then refresh note:"先在列表里选一个片段。" else (
            local name = BlimpClips_CleanName txt
            local problem = nameProblem name except:lbClips.selection
            if problem != "" then refresh note:problem else (
                if c[4] == undefined then FrameTagManager.CreateNewTag (BlimpClips_Prefix + name) (c[2] as time)
                else FrameTagManager.SetNameByID c[4] (BlimpClips_Prefix + name)
                refresh selectName:name
            )
        )
    )

    -- The clip under the slider ends just before it; a new clip, named 新片段名, starts there.
    on btnSplit pressed do (
        local name = BlimpClips_CleanName etNewName.text
        local problem = nameProblem name
        local f = sliderTime.frame
        for c in clipRows where c[4] != undefined and c[2] == f do problem = "第 " + (f as integer) as string + " 帧已经是片段 " + c[1] + " 的起点。"
        if problem != "" then refresh note:problem else (
            FrameTagManager.CreateNewTag (BlimpClips_Prefix + name) sliderTime
            refresh selectName:name
        )
    )

    on btnMoveStart pressed do (
        local c = selectedClip()
        if c == undefined or c[4] == undefined then refresh note:"先选一个有名字的片段。" else (
            BlimpClips_SetTagTime c[4] sliderTime
            refresh selectName:c[1]
        )
    )

    -- Removes the selected clip's start, so the clip before it runs on over its frames.
    on btnMerge pressed do (
        local c = selectedClip()
        if c == undefined or c[4] == undefined then refresh note:"先选一个有名字的片段。" else (
            local prev = if lbClips.selection > 1 then clipRows[lbClips.selection - 1][1] else ""
            FrameTagManager.DeleteTag c[4]
            refresh selectName:prev note:("片段 " + c[1] + " 并入了上一段。")
        )
    )

    on btnPreview pressed do (
        local c = selectedClip()
        if c == undefined or c[3] <= c[2] then refresh note:"先选一个片段。" else (
            if BlimpClips_FullRange == undefined do BlimpClips_FullRange = animationRange
            animationRange = interval c[2] c[3]
            sliderTime = c[2]
            playAnimation immediateReturn:true
        )
    )

    on btnFull pressed do (
        BlimpClips_StopPreview()
        refresh()
    )

    on btnEventAdd pressed do (
        local name = BlimpClips_CleanName etEvent.text
        if name == "" or BlimpClips_IsClipTag name then refresh note:"事件名不能是空的，也不能以 ▶ 开头。" else (
            FrameTagManager.CreateNewTag name sliderTime
            refresh()
        )
    )

    on btnEventDelete pressed do (
        if lbEvents.selection > 0 do (
            FrameTagManager.DeleteTag eventRows[lbEvents.selection][1]
            refresh()
        )
    )

    on lbEvents doubleClicked i do (
        BlimpClips_StopPreview()
        sliderTime = eventRows[i][2]
    )
    on btnRefresh pressed do refresh()
)

macroScript BlimpClips category:"Blimp" buttonText:"Blimp 动画片段" tooltip:"Blimp 动画片段：把时间轴切成片段，标记事件"
(
    try (destroyDialog BlimpClips_Rollout) catch ()
    createDialog BlimpClips_Rollout
)

-- Saving the .max writes its .clips too, so a tag moved on the timeline still reaches the file.
callbacks.removeScripts id:#BlimpClipsSave
callbacks.addScript #filePostSave "BlimpClips_Save()" id:#BlimpClipsSave

-- A "Blimp" menu in the main menu bar with this action in it (the 3ds Max 2025+ menu system). Max calls
-- #cuiRegisterMenus while it builds its menus at startup, so it shows from the next launch with this file in
-- scripts\startup. 647394 is the action table of macroScripts; an action is "macro`category". The ids are fixed
-- GUIDs, so the menu is the same one every launch.
fn BlimpClips_RegisterMenu = (
    try (
        local bar = (callbacks.notificationParam()).mainMenuBar
        local blimp = bar.CreateSubMenu "6f3c9a52-8e1d-4b7a-9c2e-5d4f1a0b3e71" "Blimp"
        blimp.CreateAction "a1d7e3b4-2c5f-4e8a-b9d0-7f6e5c4b3a29" 647394 "BlimpClips`Blimp"
    ) catch (
        format "Blimp Clips: couldn't add the Blimp menu: %\n" (getCurrentException())
    )
)
callbacks.removeScripts id:#BlimpClipsMenu
callbacks.addScript #cuiRegisterMenus BlimpClips_RegisterMenu id:#BlimpClipsMenu

-- Run by hand: open it. Loaded while Max starts (from a startup folder, or by install.bat's loader, which sets
-- BlimpClips_FromStartup): only register the action above, and note when startup is over, so running this file by
-- hand afterwards does open it.
global BlimpClips_StartupDone
global BlimpClips_FromStartup
if BlimpClips_StartupDone != true and (BlimpClips_FromStartup == true or matchPattern (getSourceFileName()) pattern:"*\\startup\\*") then (
    callbacks.removeScripts id:#BlimpClips
    callbacks.addScript #postSystemStartup "BlimpClips_StartupDone = true" id:#BlimpClips
) else (
    macros.run "Blimp" "BlimpClips"
)
