-- 城堡关卡的世界脚本（assets/scenes/castle.level），只在运行（Play）时执行。
-- 由构建转译为 castle.lua（关卡引用的是它）：改这个文件，不要改 castle.lua。
--
-- 这里每个姿态都是 世界.时间() 的函数（运行世界的游戏时钟，暂停时停止），所以脚本不保存状态
-- （CLAUDE.md：Lua 从不保存状态）。会动的实体只设为 Renderable（不是 Static / Cast Indirect），
-- 所以探针烘焙会忽略它们。

local 上 = 矢量3(0, 1, 0)
local 右 = 矢量3(1, 0, 0)
local 前 = 矢量3(0, 0, 1)

local function 平滑(x)
    x = 数学.截断(x)
    return x * x * (3 - 2 * x)
end

-- 城门循环，0 = 关闭并升起，1 = 打开并放下：开 6 秒，关闭 2 秒，关 5 秒，打开 2 秒。
local function 城门开度(t)
    local p = t % 15
    if p < 6  then return 1 end
    if p < 8  then return 1 - 平滑((p - 6) / 2) end
    if p < 13 then return 0 end
    return 平滑((p - 13) / 2)
end

local function 更新城门(t)
    local 开度 = 城门开度(t)
    local 朝向 = 四元数.轴角(上, 数学.圆周率 / 2)   -- 城门朝 -Z（它的套件部件偏航了 90 度）

    -- 吊桥：铰链在原点，沿本地 +X 平放；升起时绕本地 Z 把 +X 往上转。
    local 吊桥 = 世界.查找("drawbridge")
    if 实体.有效(吊桥) then
        实体.设四元数(吊桥, "rotation", 朝向 * 四元数.轴角(前, (1 - 开度) * 数学.角度转弧度(80)))
    end

    -- 闸门：城门打开时从拱门里升起（在吊桥放下之前先升）。
    local 闸门 = 世界.查找("portcullis")
    if 实体.有效(闸门) then
        local 位置 = 实体.取矢量(闸门, "position")
        实体.设矢量(闸门, "position", 矢量3(位置.x, 平滑(开度 * 1.5) * 0.6, 位置.z))
    end
end

-- 主塔的探照灯扫过庭院和城门前的空地。
local function 更新探照灯(t)
    local 灯 = 世界.查找("searchlight")
    if not 实体.有效(灯) then return end
    local 偏航 = 数学.圆周率 + 数学.正弦(t * 0.5) * 数学.角度转弧度(70)
    实体.设四元数(灯, "rotation", 四元数.轴角(上, 偏航) * 四元数.轴角(右, 数学.角度转弧度(38)))
end

-- 旗帜飘动，彼此错开节奏。
local function 更新旗帜(t)
    local i = 1
    while true do
        local 旗 = 世界.查找("flag_" .. i)
        if not 实体.有效(旗) then break end
        local 摆动 = 数学.正弦(t * 2.3 + i * 1.7) * 0.35 + 数学.正弦(t * 5.1 + i) * 0.08
        实体.设四元数(旗, "rotation", 四元数.轴角(上, 摆动))
        i = i + 1
    end
end

-- 光源组（世界设置）：信标闪烁，大厅的窗户每 20 秒里暗 4 秒。
local function 更新灯光(t)
    世界.设光源组("beacon", 0.55 + 0.45 * 数学.正弦(t * 3))
    世界.设光源组("windows", (t % 20) < 16 and 1 or 0)
end

-- 城门开关时的声音：gate_sound 实体（城门处，Positional）。越过 = 这一帧越过了 间隔 的整数倍。
local function 越过(t, 时间差, 间隔)
    return 数学.向下取整(t / 间隔) ~= 数学.向下取整((t - 时间差) / 间隔)
end

local function 更新城门声音(t, 时间差)
    if 越过(t - 6, 时间差, 15) or 越过(t - 13, 时间差, 15) then   -- 开始关闭 / 开始打开（城门开度）
        实体.播放声音(世界.查找("gate_sound"))
    end
end

-- ── 玩家：测试碰撞、输入和声音 ──
-- 第一人称。WASD / 左摇杆走，左 Shift / 按下左摇杆跑，鼠标 / 右摇杆看，空格 / A 跳，E / X 沿视线射线检测
-- （命中处响一声，控制台打印命中的实体），Esc 放开鼠标，左键再锁定。输入只在游戏模式（运行后）有效。
-- "player" 是一个不画的胶囊，站在它的 position 上；"main_camera" 跟在它的眼睛处。竖直速度存在 player 的
-- velocity 字段里（Lua 不保存状态）。碰撞看每个实体的 collision 字段：城墙、塔楼、地面用渲染网格，
-- 树和石头用包围盒，旗子和轮子没有；吊桥和闸门不是 Static，会跟着脚本移动并挡住玩家。
local 玩家半径 = 0.08
local 玩家身高 = 0.4
local 眼高     = 0.34
local 走速     = 1.0
local 跑速     = 2.0
local 跳速     = 1.6
local 重力     = 5.0
local 灵敏度   = 0.003   -- 每像素的弧度
local 摇杆看速 = 2.5     -- 每秒的弧度
local 出生点   = 矢量3(0, 0.05, -6)
local 步距时间 = 0.32    -- 走路时一步的秒数

local function 更新玩家(t, 时间差)
    local 玩家 = 世界.查找("player")
    local 相机 = 世界.查找("main_camera")
    if not 实体.有效(玩家) or not 实体.有效(相机) then return end

    if 输入.按下("Escape") then 输入.锁定鼠标(false) end
    if 输入.鼠标按下(1) then 输入.锁定鼠标(true) end

    -- 视角：从相机现在的朝向算出偏航和俯仰（正 = 向下看），加上这一帧的鼠标 / 摇杆。
    local 朝前 = 实体.取四元数(相机, "rotation"):旋转(前)
    local 鼠标 = 输入.鼠标移动()
    local 偏航 = 数学.反正切2(朝前.x, 朝前.z) + 鼠标.x * 灵敏度 + 输入.手柄轴("rightx") * 摇杆看速 * 时间差
    local 俯仰 = -数学.反正弦(数学.夹紧(朝前.y, -1, 1)) + 鼠标.y * 灵敏度 + 输入.手柄轴("righty") * 摇杆看速 * 时间差
    俯仰 = 数学.夹紧(俯仰, -1.4, 1.4)
    local 朝向 = 四元数.轴角(上, 偏航) * 四元数.轴角(右, 俯仰)

    -- 移动：沿偏航的水平方向。
    local 向前 = 矢量3(数学.正弦(偏航), 0, 数学.余弦(偏航))
    local 向右 = 矢量3(数学.余弦(偏航), 0, -数学.正弦(偏航))
    local 前后 = -输入.手柄轴("lefty")
    local 左右 = 输入.手柄轴("leftx")
    if 输入.按住("W") then 前后 = 前后 + 1 end
    if 输入.按住("S") then 前后 = 前后 - 1 end
    if 输入.按住("D") then 左右 = 左右 + 1 end
    if 输入.按住("A") then 左右 = 左右 - 1 end
    local 长 = 数学.开方(前后 * 前后 + 左右 * 左右)
    if 长 > 1 then
        前后 = 前后 / 长
        左右 = 左右 / 长
    end
    local 速度 = 走速
    if 输入.按住("Left Shift") or 输入.手柄按住("leftstick") then 速度 = 跑速 end
    local 水平 = (向前 * 前后 + 向右 * 左右) * 速度

    -- 重力和跳跃：竖直速度是 player 的 velocity.y。站在地上时轻轻压住地面，好让下一帧还算着地。
    local 竖直 = 实体.取矢量(玩家, "velocity").y - 重力 * 时间差
    local 着地 = 实体.移动(玩家, 矢量3(水平.x * 时间差, 竖直 * 时间差, 水平.z * 时间差), 玩家半径, 玩家身高)
    if 着地 and 竖直 < 0 then 竖直 = -0.1 end
    if 着地 and (输入.按下("Space") or 输入.手柄按下("a")) then
        竖直 = 跳速
        世界.播放声音("assets/sounds/jump.wav", 0.5)
    end
    实体.设矢量(玩家, "velocity", 矢量3(0, 竖直, 0))

    local 位置 = 实体.取矢量(玩家, "position")
    if 位置.y < -5 then   -- 掉出了世界：回到出生点
        位置 = 出生点
        实体.设矢量(玩家, "position", 位置)
        实体.设矢量(玩家, "velocity", 矢量3(0, 0, 0))
    end
    local 眼 = 位置 + 上 * 眼高
    实体.设矢量(相机, "position", 眼)
    实体.设四元数(相机, "rotation", 朝向)

    -- 脚步声：在地上走动时每 步距时间 一步，跑时按速度加快。
    if 着地 and 长 > 0.1 and 越过(t, 时间差, 步距时间 * 走速 / 速度) then
        世界.在位置播放声音("assets/sounds/footstep.wav", 位置, 0.7)
    end

    -- 射线检测：沿视线 8 个单位。
    if 输入.按下("E") or 输入.手柄按下("x") then
        local 命中, 点, 法线, 实体号 = 世界.射线检测(眼, 朝向:旋转(前), 8)
        if 命中 then
            世界.在位置播放声音("assets/sounds/ping.wav", 点)
            打印("射线命中 " .. 实体.取文本(实体号, "name") .. " " .. 转文本(点))
        end
    end
end

function 世界.开始()
    打印("castle.luacn: 开始")
    -- 相机从玩家的朝向开始（关卡里的 main_camera 是编辑器里的俯瞰视角）。
    local 玩家 = 世界.查找("player")
    local 相机 = 世界.查找("main_camera")
    if 实体.有效(玩家) and 实体.有效(相机) then
        实体.设四元数(相机, "rotation", 实体.取四元数(玩家, "rotation"))
        输入.锁定鼠标(true)
    end
end

function 世界.更新(时间差)
    local t = 世界.时间()
    更新城门(t)
    更新城门声音(t, 时间差)
    更新探照灯(t)
    更新旗帜(t)
    更新灯光(t)
    更新玩家(t, 时间差)
end
