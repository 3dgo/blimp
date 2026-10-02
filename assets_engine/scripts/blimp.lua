local blimp = {
}

function blimp._wire()
    blimp._start  = blimp.开始  or blimp.start  or function() end
    blimp._update = blimp.更新  or blimp.update or function(_) end
    blimp._finish = blimp.完结  or blimp.finish or function() end
end

return blimp