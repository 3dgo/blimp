---@meta
-- LuaLS 中文 API 类型定义（仅中文全局变量与类型）。只给语言服务器看，引擎不加载这个文件。
-- 每个字段上面的 --- 注释就是补全和悬停时显示的说明。

-- ── 数学 ──────────────────────────────────────────────────────────────

---数学函数。角度一律是弧度。
---@class CmathZH
---π ≈ 3.14159
---@field 圆周率     number
---e ≈ 2.71828
---@field 自然常数   number
---正无穷大
---@field 无穷大     number
---平方根
---@field 开方       fun(x: number): number
---绝对值
---@field 绝对值     fun(x: number): number
---正弦（弧度）
---@field 正弦       fun(弧度: number): number
---余弦（弧度）
---@field 余弦       fun(弧度: number): number
---正切（弧度）
---@field 正切       fun(弧度: number): number
---反正弦，返回弧度
---@field 反正弦     fun(x: number): number
---反余弦，返回弧度
---@field 反余弦     fun(x: number): number
---反正切，返回弧度
---@field 反正切     fun(x: number): number
---点 (x, y) 的方位角（弧度，-π 到 π）。注意 y 在前。
---@field 反正切2    fun(y: number, x: number): number
---x 的 y 次方
---@field 幂         fun(x: number, y: number): number
---e 的 x 次方
---@field 指数       fun(x: number): number
---自然对数
---@field 对数       fun(x: number): number
---以 2 为底的对数
---@field 二进制对数 fun(x: number): number
---以 10 为底的对数
---@field 常用对数   fun(x: number): number
---向下取整
---@field 向下取整   fun(x: number): number
---向上取整
---@field 向上取整   fun(x: number): number
---四舍五入到整数
---@field 四舍五入   fun(x: number): number
---x 除以 y 的余数，符号同 x
---@field 浮点取余   fun(x: number, y: number): number
---正数 1，负数 -1，零 0
---@field 符号       fun(x: number): number
---较小的一个
---@field 最小值     fun(甲: number, 乙: number): number
---较大的一个
---@field 最大值     fun(甲: number, 乙: number): number
---把 x 限制在 [最小, 最大] 之间
---@field 夹紧       fun(x: number, 最小: number, 最大: number): number
---把 x 限制在 [0, 1] 之间
---@field 截断       fun(x: number): number
---从 甲 到 乙 线性插值：比例 0 = 甲，1 = 乙
---@field 插值       fun(甲: number, 乙: number, 比例: number): number
---x 小于 边界 时为 0，否则为 1
---@field 阶跃       fun(边界: number, x: number): number
---x 从 下限 到 上限 时，从 0 平滑过渡到 1（两端放缓）
---@field 平滑阶跃   fun(下限: number, 上限: number, x: number): number
---弧度转成角度
---@field 弧度转角度 fun(弧度: number): number
---角度转成弧度
---@field 角度转弧度 fun(角度: number): number

---数学函数：开方、正弦、夹紧、插值……角度一律是弧度。
---@type CmathZH
数学 = nil

-- ── 矢量2 ─────────────────────────────────────────────────────────────

---二维矢量。支持 + - *（与数字或同类相乘）和取负。
---@class Vec2ZH
---@field x number
---@field y number
---点积
---@field 点乘   fun(self: Vec2ZH, 另一个: Vec2ZH): number
---二维叉积：x1*y2 - y1*x2（一个数字）
---@field 叉乘   fun(self: Vec2ZH, 另一个: Vec2ZH): number
---长度
---@field 长度   fun(self: Vec2ZH): number
---方向相同、长度为 1 的矢量
---@field 标准化 fun(self: Vec2ZH): Vec2ZH
---插值到 目标：比例 0 = 自己，1 = 目标
---@field 插值   fun(self: Vec2ZH, 目标: Vec2ZH, 比例: number): Vec2ZH

---新建二维矢量
---@type fun(x: number, y: number): Vec2ZH
矢量2 = nil

-- ── 矢量3 ─────────────────────────────────────────────────────────────

---三维矢量：位置、方向、颜色。支持 + - *（与数字或同类相乘）和取负。
---坐标系：左手系，Y 向上，+Z 向前，+X 向右。
---@class Vec3ZH
---@field x number
---@field y number
---@field z number
---点积
---@field 点乘   fun(self: Vec3ZH, 另一个: Vec3ZH): number
---叉积：同时垂直于两者的矢量
---@field 叉乘   fun(self: Vec3ZH, 另一个: Vec3ZH): Vec3ZH
---长度
---@field 长度   fun(self: Vec3ZH): number
---方向相同、长度为 1 的矢量
---@field 标准化 fun(self: Vec3ZH): Vec3ZH
---插值到 目标：比例 0 = 自己，1 = 目标
---@field 插值   fun(self: Vec3ZH, 目标: Vec3ZH, 比例: number): Vec3ZH

---新建三维矢量。左手系：Y 向上，+Z 向前，+X 向右。
---@type fun(x: number, y: number, z: number): Vec3ZH
矢量3 = nil

-- ── 矢量4 ─────────────────────────────────────────────────────────────

---四维矢量，比如带透明度的颜色。支持 + - *（与数字或同类相乘）和取负。
---@class Vec4ZH
---@field x number
---@field y number
---@field z number
---@field w number
---点积
---@field 点乘   fun(self: Vec4ZH, 另一个: Vec4ZH): number
---长度
---@field 长度   fun(self: Vec4ZH): number
---方向相同、长度为 1 的矢量
---@field 标准化 fun(self: Vec4ZH): Vec4ZH
---插值到 目标：比例 0 = 自己，1 = 目标
---@field 插值   fun(self: Vec4ZH, 目标: Vec4ZH, 比例: number): Vec4ZH

---新建四维矢量
---@type fun(x: number, y: number, z: number, w: number): Vec4ZH
矢量4 = nil

-- ── 四元数 ────────────────────────────────────────────────────────────

---四元数：一个朝向或一次转动。a * b 表示先转 b 再转 a（相对本地坐标）。
---@class QuatZH
---@field x number
---@field y number
---@field z number
---@field w number
---长度（表示朝向的四元数长度为 1）
---@field 长度   fun(self: QuatZH): number
---长度为 1 的四元数
---@field 标准化 fun(self: QuatZH): QuatZH
---共轭；长度为 1 时就是反向的转动
---@field 共轭   fun(self: QuatZH): QuatZH
---反向的转动
---@field 逆     fun(self: QuatZH): QuatZH
---点积
---@field 点乘   fun(self: QuatZH, 另一个: QuatZH): number
---把矢量转到这个朝向下。例如 朝向:旋转(矢量3(0, 0, 1)) 是朝前的方向。
---@field 旋转   fun(self: QuatZH, 矢量: Vec3ZH): Vec3ZH
---球面插值到 目标：比例 0 = 自己，1 = 目标
---@field 球面插值 fun(self: QuatZH, 目标: QuatZH, 比例: number): QuatZH

---@class QuatZHClass : QuatZH
---@overload fun(x: number, y: number, z: number, w: number): QuatZH
---不转动（单位四元数）
---@field 单位   fun(): QuatZH
---绕 轴 转 弧度（轴不必是单位长度）
---@field 轴角   fun(轴: Vec3ZH, 弧度: number): QuatZH
---由欧拉角（弧度）得到朝向：俯仰绕 X，偏航绕 Y，滚转绕 Z
---@field 欧拉角 fun(俯仰: number, 偏航: number, 滚转: number): QuatZH

---四元数：四元数(x, y, z, w)，或 四元数.单位()、四元数.轴角(轴, 弧度)、四元数.欧拉角(俯仰, 偏航, 滚转)。
---@type QuatZHClass
四元数 = nil

-- ── 矩阵3 ─────────────────────────────────────────────────────────────

---3×3 矩阵：旋转和缩放。m 按列存放。
---@class Mat3ZH
---@field m number[]
---转置
---@field 转置     fun(self: Mat3ZH): Mat3ZH
---逆矩阵
---@field 逆矩阵   fun(self: Mat3ZH): Mat3ZH
---用这个矩阵变换矢量
---@field 变换     fun(self: Mat3ZH, 矢量: Vec3ZH): Vec3ZH
---变换法线用的矩阵（逆矩阵的转置）
---@field 法线矩阵 fun(self: Mat3ZH): Mat3ZH

---@class Mat3ZHClass : Mat3ZH
---@overload fun(): Mat3ZH
---单位矩阵
---@field 单位     fun(): Mat3ZH
---由四元数得到旋转矩阵
---@field 从四元数 fun(四元数: QuatZH): Mat3ZH

---3×3 矩阵：矩阵3()、矩阵3.单位()、矩阵3.从四元数(四元数)。
---@type Mat3ZHClass
矩阵3 = nil

-- ── 矩阵4 ─────────────────────────────────────────────────────────────

---4×4 变换矩阵：平移、旋转、缩放。m 按列存放。
---@class Mat4ZH
---@field m number[]
---转置
---@field 转置     fun(self: Mat4ZH): Mat4ZH
---逆矩阵
---@field 逆矩阵   fun(self: Mat4ZH): Mat4ZH
---变换一个点（包括平移）
---@field 变换点   fun(self: Mat4ZH, 点: Vec3ZH): Vec3ZH
---变换一个方向（不包括平移）
---@field 变换方向 fun(self: Mat4ZH, 方向: Vec3ZH): Vec3ZH
---变换一个四维矢量
---@field 变换向量 fun(self: Mat4ZH, 矢量: Vec4ZH): Vec4ZH
---左上角的 3×3 部分（旋转和缩放）
---@field 转矩阵3  fun(self: Mat4ZH): Mat3ZH

---@class Mat4ZHClass : Mat4ZH
---@overload fun(): Mat4ZH
---单位矩阵
---@field 单位     fun(): Mat4ZH
---平移矩阵
---@field 平移     fun(x: number, y: number, z: number): Mat4ZH
---缩放矩阵（每个轴一个倍数）
---@field 缩放     fun(x: number, y: number, z: number): Mat4ZH
---绕 X 轴旋转 弧度
---@field 绕X旋转  fun(弧度: number): Mat4ZH
---绕 Y 轴旋转 弧度
---@field 绕Y旋转  fun(弧度: number): Mat4ZH
---绕 Z 轴旋转 弧度
---@field 绕Z旋转  fun(弧度: number): Mat4ZH
---由四元数得到旋转矩阵
---@field 从四元数 fun(四元数: QuatZH): Mat4ZH
---由位置、朝向、缩放组成变换矩阵（先缩放，再旋转，再平移）
---@field 变换矩阵 fun(位置: Vec3ZH, 朝向: QuatZH, 缩放: Vec3ZH): Mat4ZH
---观察矩阵：从 眼睛 看向 目标
---@field 观察     fun(眼睛: Vec3ZH, 目标: Vec3ZH, 上方: Vec3ZH): Mat4ZH
---透视投影矩阵（视角为竖直方向的弧度）
---@field 透视     fun(视角: number, 宽高比: number, 近: number, 远: number): Mat4ZH
---正交投影矩阵
---@field 正交     fun(左: number, 右: number, 下: number, 上: number, 近: number, 远: number): Mat4ZH

---4×4 矩阵：矩阵4()、矩阵4.单位()、矩阵4.变换矩阵(位置, 朝向, 缩放)……
---@type Mat4ZHClass
矩阵4 = nil

-- ── 回调 ──────────────────────────────────────────────────────────────
-- 这些函数由脚本自己定义，引擎在对应的时候调用。写在这里只为了补全和悬停说明。

---引擎：main.lua 定义的会话级回调（开始、更新、完结），不属于任何关卡。
---@class 引擎
引擎 = nil

---main.lua 加载后（以及它热重载后）调用一次。由 main.lua 定义。
function 引擎.开始() end

---每帧调用一次，编辑和运行时都会调用。不在任何世界里：世界、实体、动画的接口在这里不能用，只能用 输入。
---@param 时间差 number 这一帧的秒数
function 引擎.更新(时间差) end

---引擎关闭前调用一次。由 main.lua 定义。
function 引擎.完结() end

---每次按下运行时（以及脚本热重载后）调用一次。在这里用 世界.获取 取关卡里固定的实体。
function 世界.开始() end

---关卡每前进一帧调用一次：暂停时不调用，F10 单步时调用一次。动画请基于 世界.时间()。
---@param 时间差 number 这一帧的秒数
function 世界.更新(时间差) end

---角色的动画片段播过一个事件（.clips 文件里标的帧，比如脚落地）之后调用。
---只有占当前姿态一半以上的片段才触发，所以混合时不会响两遍；跳转不触发。
---@param 实体 实体句柄 播放片段的实体
---@param 名字 string 事件名，如 "footstep"
function 世界.动画事件(实体, 名字) end

---每帧调用，暂停时也调用，每个显示这个世界的视口各一次：用 界面.* 画游戏的屏幕界面（分数、暂停菜单）。
---只画界面、响应按钮；游戏逻辑放在 世界.更新 里。
function 世界.界面() end

-- ── 标准 Lua 全局变量（中文别名）────────────────────────────────────

打印         = print
断言         = assert
报错         = error
类型         = type
转文本       = tostring
转数字       = tonumber
遍历         = pairs
遍历列表     = ipairs
下一个       = next
选择         = select
安全调用     = pcall
扩展安全调用 = xpcall
设元表       = setmetatable
取元表       = getmetatable
展开         = unpack
引入         = require
原始取       = rawget
原始设       = rawset
原始相等     = rawequal

-- ── 字符串 ────────────────────────────────────────────────────────────

---字符串函数（Lua 的 string 库）。位置从 1 开始，负数从末尾数。
---@class 字符串ZH
---第 起 到 止 个字节的数值
---@field 字节     fun(文本: string, 起?: integer, 止?: integer): integer
---由字节数值组成字符串
---@field 字符     fun(...: integer): string
---把函数转成二进制代码字符串
---@field 转储     fun(函数: function, 去调试信息?: boolean): string
---查找 模式，返回起止位置（找不到返回 nil）。纯文本 为真时不按模式匹配。
---@field 查找     fun(文本: string, 模式: string, 起?: integer, 纯文本?: boolean): integer?, integer?, ...
---按格式生成字符串，如 字符串.格式化("%d 分", 分数)、"%.2f"、"%s"
---@field 格式化   fun(格式: string, ...): string
---遍历所有匹配 模式 的片段
---@field 全局匹配 fun(文本: string, 模式: string): fun(): string
---把所有匹配 模式 的片段换成 替换，返回新字符串和替换次数
---@field 全局替换 fun(文本: string, 模式: string, 替换: string|table|function, 最多?: integer): string, integer
---字节数（一个汉字占 3 个字节）
---@field 长度     fun(文本: string): integer
---转小写
---@field 小写     fun(文本: string): string
---第一个匹配 模式 的片段（有捕获时返回捕获）
---@field 匹配     fun(文本: string, 模式: string, 起?: integer): string
---重复 次数 遍
---@field 重复     fun(文本: string, 次数: integer): string
---反转字节顺序
---@field 反转     fun(文本: string): string
---第 起 到 止 个字节的子串
---@field 截取     fun(文本: string, 起: integer, 止?: integer): string
---转大写
---@field 大写     fun(文本: string): string

---字符串函数（Lua 的 string 库）
---@type 字符串ZH
字符串 = nil

-- ── 表 ────────────────────────────────────────────────────────────────

---表函数（Lua 的 table 库）
---@class 表ZH
---把列表里的字符串用 分隔符 连起来
---@field 合并 fun(列表: table, 分隔符?: string, 起?: integer, 止?: integer): string
---加到列表末尾
---@field 插入 fun(列表: table, 值: any)
---移除第 位置 个元素（默认最后一个）并返回它
---@field 移除 fun(列表: table, 位置?: integer): any
---原地排序；比较 返回真表示 甲 排在 乙 前面
---@field 排序 fun(列表: table, 比较?: fun(甲: any, 乙: any): boolean)

---表函数（Lua 的 table 库）
---@type 表ZH
表 = nil

-- ── 协程 ──────────────────────────────────────────────────────────────

---协程函数（Lua 的 coroutine 库）
---@class 协程ZH
---用函数新建一个协程
---@field 创建   fun(函数: function): thread
---开始或继续运行协程，返回是否成功和它 让出 的值
---@field 恢复   fun(协程: thread, ...: any): boolean, ...
---当前正在运行的协程
---@field 运行中 fun(): thread, boolean
---协程的状态："suspended"、"running"、"normal"、"dead"
---@field 状态   fun(协程: thread): string
---新建协程，返回一个每次调用就继续运行它的函数
---@field 包装   fun(函数: function): function
---暂停当前协程，把值交给 恢复
---@field 让出   fun(...: any): ...

---协程函数（Lua 的 coroutine 库）
---@type 协程ZH
协程 = nil

-- ── 文件 ──────────────────────────────────────────────────────────────

---文件函数（Lua 的 io 库）
---@class 文件ZH
---关闭文件
---@field 关闭     fun(文件?: file*): boolean, string?, integer?
---把缓冲写入默认输出文件
---@field 刷新     fun()
---设置或取得默认输入文件
---@field 输入     fun(文件?: string|file*): file*
---逐行遍历文件
---@field 行迭代   fun(文件名?: string): fun(): string
---打开文件，模式如 "r"、"w"、"a"、"rb"
---@field 打开     fun(文件名: string, 模式?: openmode): file*, string?
---设置或取得默认输出文件
---@field 输出     fun(文件?: string|file*): file*
---运行程序，返回读写它的文件
---@field 管道打开 fun(程序: string, 模式?: string): file*
---从默认输入文件读取
---@field 读取     fun(...): string|number|nil
---标准错误输出
---@field 标准错误 file*
---标准输入
---@field 标准输入 file*
---标准输出
---@field 标准输出 file*
---新建一个临时文件
---@field 临时文件 fun(): file*
---对象是不是文件："file"、"closed file" 或 nil
---@field 类型     fun(对象: any): string
---写入默认输出文件
---@field 写入     fun(...: string|number)

---文件函数（Lua 的 io 库）
---@type 文件ZH
文件 = nil

-- ── 系统 ──────────────────────────────────────────────────────────────

---系统函数（Lua 的 os 库）。游戏逻辑的时间用 世界.时间()，不要用这里的时钟。
---@class 系统ZH
---程序用掉的 CPU 秒数
---@field 时钟         fun(): number
---格式化日期，如 系统.日期("%Y-%m-%d")
---@field 日期         fun(格式?: string, 时间?: integer): string|osdate
---两个时间相差的秒数
---@field 时差         fun(时间2: integer, 时间1: integer): integer
---运行系统命令
---@field 执行         fun(命令?: string): boolean?, string?, integer?
---退出程序
---@field 退出         fun(代码?: boolean|integer)
---环境变量的值
---@field 取环境变量   fun(变量名: string): string?
---删除文件
---@field 删除         fun(文件名: string): boolean, string?, integer?
---重命名文件
---@field 重命名       fun(旧名: string, 新名: string): boolean, string?, integer?
---设置语言环境
---@field 设置语言环境 fun(语言环境: string, 类别?: string): string?
---当前时间（从 1970 年起的秒数），或把日期表转成时间
---@field 时间         fun(日期?: osdateparam): integer
---一个可用作临时文件的文件名
---@field 临时名称     fun(): string

---系统函数（Lua 的 os 库）
---@type 系统ZH
系统 = nil
