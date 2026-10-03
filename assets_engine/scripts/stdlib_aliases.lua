-- Standard library aliases — Chinese names for libraries and their functions.
-- Each Chinese global is a FRESH table so the English builtins stay unmodified.
-- Types are declared in lua_chinese_defs.lua.

_G.打印         = print
_G.断言         = assert
_G.报错         = error
_G.类型         = type
_G.转文本       = tostring
_G.转数字       = tonumber
_G.遍历         = pairs
_G.遍历列表     = ipairs
_G.下一个       = next
_G.选择         = select
_G.安全调用     = pcall
_G.扩展安全调用 = xpcall
_G.设元表       = setmetatable
_G.取元表       = getmetatable
_G.展开         = unpack
_G.引入         = require
_G.原始取       = rawget
_G.原始设       = rawset
_G.原始相等     = rawequal

_G.字符串 = {
    字节     = string.byte,
    字符     = string.char,
    转储     = string.dump,
    查找     = string.find,
    格式化   = string.format,
    全局匹配 = string.gmatch,
    全局替换 = string.gsub,
    长度     = string.len,
    小写     = string.lower,
    匹配     = string.match,
    重复     = string.rep,
    反转     = string.reverse,
    截取     = string.sub,
    大写     = string.upper,
} --[[@as 字符串ZH]]

_G.表 = {
    合并 = table.concat,
    插入 = table.insert,
    移除 = table.remove,
    排序 = table.sort,
} --[[@as 表ZH]]

_G.协程 = {
    创建   = coroutine.create,
    恢复   = coroutine.resume,
    运行中 = coroutine.running,
    状态   = coroutine.status,
    包装   = coroutine.wrap,
    让出   = coroutine.yield,
} --[[@as 协程ZH]]

_G.文件 = {
    关闭     = io.close,
    刷新     = io.flush,
    输入     = io.input,
    行迭代   = io.lines,
    打开     = io.open,
    输出     = io.output,
    管道打开 = io.popen,
    读取     = io.read,
    标准错误 = io.stderr,
    标准输入 = io.stdin,
    标准输出 = io.stdout,
    临时文件 = io.tmpfile,
    类型     = io.type,
    写入     = io.write,
} --[[@as 文件ZH]]

_G.系统 = {
    时钟         = os.clock,
    日期         = os.date,
    时差         = os.difftime,
    执行         = os.execute,
    退出         = os.exit,
    取环境变量   = os.getenv,
    删除         = os.remove,
    重命名       = os.rename,
    设置语言环境 = os.setlocale,
    时间         = os.time,
    临时名称     = os.tmpname,
} --[[@as 系统ZH]]
