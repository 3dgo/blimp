local 位置1 = 矢量3(1, 0, 0)
local 位置2 = 矢量3(0, 1, 0)

function 引擎.开始()
    local 位置3 = 位置1 + 位置2
    打印(位置3)

    -- 实体系统冒烟测试：查找、读取、写入（含 schema 生成的字段）
    local 车 = 世界.查找("car")
    if 实体.有效(车) then
        实体.设文本(车, "name", "英雄车")
        打印(实体.取文本(车, "name"))
        实体.设矢量(车, "position", 矢量3(2, 0, 0))
        打印(实体.取矢量(车, "position"))
    end
end

function 引擎.更新(时间差)
end

function 引擎.完结()
end