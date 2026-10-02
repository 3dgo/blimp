---@meta
-- LuaLS 中文 API 类型定义（仅中文全局变量与类型）

-- ── 数学 ──────────────────────────────────────────────────────────────

---@class CmathZH
---@field 圆周率     number
---@field 自然常数   number
---@field 无穷大     number
---@field 开方       fun(x: number): number
---@field 绝对值     fun(x: number): number
---@field 正弦       fun(x: number): number
---@field 余弦       fun(x: number): number
---@field 正切       fun(x: number): number
---@field 反正弦     fun(x: number): number
---@field 反余弦     fun(x: number): number
---@field 反正切     fun(x: number): number
---@field 反正切2    fun(y: number, x: number): number
---@field 幂         fun(x: number, y: number): number
---@field 指数       fun(x: number): number
---@field 对数       fun(x: number): number
---@field 二进制对数 fun(x: number): number
---@field 常用对数   fun(x: number): number
---@field 向下取整   fun(x: number): number
---@field 向上取整   fun(x: number): number
---@field 四舍五入   fun(x: number): number
---@field 浮点取余   fun(x: number, y: number): number
---@field 符号       fun(x: number): number
---@field 最小值     fun(a: number, b: number): number
---@field 最大值     fun(a: number, b: number): number
---@field 夹紧       fun(x: number, lo: number, hi: number): number
---@field 截断       fun(x: number): number
---@field 插值       fun(a: number, b: number, t: number): number
---@field 阶跃       fun(edge: number, x: number): number
---@field 平滑阶跃   fun(lo: number, hi: number, x: number): number
---@field 弧度转角度 fun(r: number): number
---@field 角度转弧度 fun(d: number): number

---@type CmathZH
数学 = nil

-- ── 矢量2 ─────────────────────────────────────────────────────────────

---@class Vec2ZH
---@field x number
---@field y number
---@field 点乘   fun(self: Vec2ZH, b: Vec2ZH): number
---@field 叉乘   fun(self: Vec2ZH, b: Vec2ZH): number
---@field 长度   fun(self: Vec2ZH): number
---@field 标准化 fun(self: Vec2ZH): Vec2ZH
---@field 插值   fun(self: Vec2ZH, b: Vec2ZH, t: number): Vec2ZH

---@type fun(x: number, y: number): Vec2ZH
矢量2 = nil

-- ── 矢量3 ─────────────────────────────────────────────────────────────

---@class Vec3ZH
---@field x number
---@field y number
---@field z number
---@field 点乘   fun(self: Vec3ZH, b: Vec3ZH): number
---@field 叉乘   fun(self: Vec3ZH, b: Vec3ZH): Vec3ZH
---@field 长度   fun(self: Vec3ZH): number
---@field 标准化 fun(self: Vec3ZH): Vec3ZH
---@field 插值   fun(self: Vec3ZH, b: Vec3ZH, t: number): Vec3ZH

---@type fun(x: number, y: number, z: number): Vec3ZH
矢量3 = nil

-- ── 矢量4 ─────────────────────────────────────────────────────────────

---@class Vec4ZH
---@field x number
---@field y number
---@field z number
---@field w number
---@field 点乘   fun(self: Vec4ZH, b: Vec4ZH): number
---@field 长度   fun(self: Vec4ZH): number
---@field 标准化 fun(self: Vec4ZH): Vec4ZH
---@field 插值   fun(self: Vec4ZH, b: Vec4ZH, t: number): Vec4ZH

---@type fun(x: number, y: number, z: number, w: number): Vec4ZH
矢量4 = nil

-- ── 四元数 ────────────────────────────────────────────────────────────

---@class QuatZH
---@field x number
---@field y number
---@field z number
---@field w number
---@field 长度   fun(self: QuatZH): number
---@field 标准化 fun(self: QuatZH): QuatZH
---@field 共轭   fun(self: QuatZH): QuatZH
---@field 逆     fun(self: QuatZH): QuatZH
---@field 点乘   fun(self: QuatZH, b: QuatZH): number
---@field 旋转   fun(self: QuatZH, v: Vec3ZH): Vec3ZH
---@field 球面插值 fun(self: QuatZH, b: QuatZH, t: number): QuatZH

---@class QuatZHClass : QuatZH
---@overload fun(x: number, y: number, z: number, w: number): QuatZH
---@field 单位   fun(): QuatZH
---@field 轴角   fun(axis: Vec3ZH, angle: number): QuatZH
---@field 欧拉角 fun(pitch: number, yaw: number, roll: number): QuatZH

---@type QuatZHClass
四元数 = nil

-- ── 矩阵3 ─────────────────────────────────────────────────────────────

---@class Mat3ZH
---@field m number[]
---@field 转置     fun(self: Mat3ZH): Mat3ZH
---@field 逆矩阵   fun(self: Mat3ZH): Mat3ZH
---@field 变换     fun(self: Mat3ZH, v: Vec3ZH): Vec3ZH
---@field 法线矩阵 fun(self: Mat3ZH): Mat3ZH

---@class Mat3ZHClass : Mat3ZH
---@overload fun(): Mat3ZH
---@field 单位     fun(): Mat3ZH
---@field 从四元数 fun(q: QuatZH): Mat3ZH

---@type Mat3ZHClass
矩阵3 = nil

-- ── 矩阵4 ─────────────────────────────────────────────────────────────

---@class Mat4ZH
---@field m number[]
---@field 转置     fun(self: Mat4ZH): Mat4ZH
---@field 逆矩阵   fun(self: Mat4ZH): Mat4ZH
---@field 变换点   fun(self: Mat4ZH, v: Vec3ZH): Vec3ZH
---@field 变换方向 fun(self: Mat4ZH, v: Vec3ZH): Vec3ZH
---@field 变换向量 fun(self: Mat4ZH, v: Vec4ZH): Vec4ZH
---@field 转矩阵3  fun(self: Mat4ZH): Mat3ZH

---@class Mat4ZHClass : Mat4ZH
---@overload fun(): Mat4ZH
---@field 单位     fun(): Mat4ZH
---@field 平移     fun(v: Vec3ZH): Mat4ZH
---@field 缩放     fun(v: Vec3ZH): Mat4ZH
---@field 绕X旋转  fun(angle: number): Mat4ZH
---@field 绕Y旋转  fun(angle: number): Mat4ZH
---@field 绕Z旋转  fun(angle: number): Mat4ZH
---@field 从四元数 fun(q: QuatZH): Mat4ZH
---@field 变换矩阵 fun(t: Vec3ZH, r: QuatZH, s: Vec3ZH): Mat4ZH
---@field 观察     fun(eye: Vec3ZH, center: Vec3ZH, up: Vec3ZH): Mat4ZH
---@field 透视     fun(fov: number, aspect: number, near: number, far: number): Mat4ZH
---@field 正交     fun(l: number, r: number, b: number, t: number, near: number, far: number): Mat4ZH

---@type Mat4ZHClass
矩阵4 = nil

-- ── 引擎 ──────────────────────────────────────────────────────────────

---@class 引擎
引擎 = nil

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
原始长度     = rawlen

-- ── 字符串 ────────────────────────────────────────────────────────────

---@class 字符串ZH
---@field 字节     fun(s: string, i?: integer, j?: integer): integer
---@field 字符     fun(...: integer): string
---@field 转储     fun(f: function, strip?: boolean): string
---@field 查找     fun(s: string, pattern: string, init?: integer, plain?: boolean): integer?, integer?, ...
---@field 格式化   fun(s: string, ...): string
---@field 全局匹配 fun(s: string, pattern: string): fun(): string
---@field 全局替换 fun(s: string, pattern: string, repl: string|table|function, n?: integer): string, integer
---@field 长度     fun(s: string): integer
---@field 小写     fun(s: string): string
---@field 匹配     fun(s: string, pattern: string, init?: integer): string
---@field 重复     fun(s: string, n: integer): string
---@field 反转     fun(s: string): string
---@field 截取     fun(s: string, i: integer, j?: integer): string
---@field 大写     fun(s: string): string

---@type 字符串ZH
字符串 = nil

-- ── 表 ────────────────────────────────────────────────────────────────

---@class 表ZH
---@field 合并 fun(list: table, sep?: string, i?: integer, j?: integer): string
---@field 插入 fun(list: table, value: any)
---@field 移除 fun(list: table, pos?: integer): any
---@field 排序 fun(list: table, comp?: fun(a: any, b: any): boolean)

---@type 表ZH
表 = nil

-- ── 协程 ──────────────────────────────────────────────────────────────

---@class 协程ZH
---@field 创建   fun(f: function): thread
---@field 恢复   fun(co: thread, ...: any): boolean, ...
---@field 运行中 fun(): thread, boolean
---@field 状态   fun(co: thread): string
---@field 包装   fun(f: function): function
---@field 让出   fun(...: any): ...

---@type 协程ZH
协程 = nil

-- ── 文件 ──────────────────────────────────────────────────────────────

---@class 文件ZH
---@field 关闭     fun(file?: file*): boolean, string?, integer?
---@field 刷新     fun()
---@field 输入     fun(file?: string|file*): file*
---@field 行迭代   fun(filename?: string): fun(): string
---@field 打开     fun(filename: string, mode?: openmode): file*, string?
---@field 输出     fun(file?: string|file*): file*
---@field 管道打开 fun(prog: string, mode?: string): file*
---@field 读取     fun(...): string|number|nil
---@field 标准错误 file*
---@field 标准输入 file*
---@field 标准输出 file*
---@field 临时文件 fun(): file*
---@field 类型     fun(obj: any): string
---@field 写入     fun(...: string|number)

---@type 文件ZH
文件 = nil

-- ── 系统 ──────────────────────────────────────────────────────────────

---@class 系统ZH
---@field 时钟         fun(): number
---@field 日期         fun(format?: string, time?: integer): string|osdate
---@field 时差         fun(t2: integer, t1: integer): integer
---@field 执行         fun(command?: string): boolean?, string?, integer?
---@field 退出         fun(code?: boolean|integer)
---@field 取环境变量   fun(varname: string): string?
---@field 删除         fun(filename: string): boolean, string?, integer?
---@field 重命名       fun(oldname: string, newname: string): boolean, string?, integer?
---@field 设置语言环境 fun(locale: string, category?: string): string?
---@field 时间         fun(table?: osdateparam): integer
---@field 临时名称     fun(): string

---@type 系统ZH
系统 = nil
