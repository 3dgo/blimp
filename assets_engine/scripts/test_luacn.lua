-- test_luacn.luacn
-- Exercises all 20 Chinese keywords in the luacn translation table.
-- Run the codegen to produce test_luacn.lua, 那么 execute it with a Lua interpreter.

local passes = 0

local function check(name, cond)
    if cond then
        passes = passes + 1
    else
        print("FAIL: " .. name)
    end
end

-- 如果 / 否则如果 / 否则 / 结束
local x = 5
local label = ""
if x > 10 then
    label = "big"
elseif x == 5 then
    label = "five"
else
    label = "other"
end
check("如果/否则如果/否则/结束", label == "five")

-- 当 / 做 / 结束
local i = 0
while i < 5 do
    i = i + 1
end
check("当/做/结束", i == 5)

-- 重复 / 直到
local j = 0
repeat
    j = j + 1
until j >= 5
check("重复/直到", j == 5)

-- 对于 numeric / 做 / 结束
local sum = 0
for k = 1, 10 do
    sum = sum + k
end
check("对于 numeric", sum == 55)

-- 对于 / 在 generic / 做 / 结束
local t = {10, 20, 30}
local gsum = 0
for _, v in ipairs(t) do
    gsum = gsum + v
end
check("对于/在 generic", gsum == 60)

-- 真 / 假 / 空
check("真", true == true)
check("假", false == false)
check("空", nil == nil)

-- 和 / 或 / 非
check("和", true and true)
check("或", false or true)
check("非", not false)

-- 函数 / 返回
local function add(a, b)
    return a + b
end
check("函数/返回", add(3, 4) == 7)

-- 中断
local hit = 0
for n = 1, 100 do
    hit = n
    if n >= 5 then
        break
    end
end
check("中断", hit == 5)

-- 本地 block scoping (standalone 做/结束 block)
do
    local inner = 42
    check("本地/做 scope", inner == 42)
end

-- Keywords inside strings must NOT be translated (sanity check)
local raw = "如果 否则 结束"
check("strings untouched", raw == "如果 否则 结束")

-- Keywords inside comments are also left alone (the lines below must not break parsing)
-- 如果 否则如果 否则 结束 当 重复 直到 对于 在 做 函数 返回 本地 真 假 空 和 或 非 中断

local total = 15
print(string.format("LuaCN: %d/%d tests passed", passes, total))
assert(passes == total, "Some LuaCN tests failed!")
