---@diagnostic disable
-- LuaLS plugin: transpile .luacn files before analysis so the language server
-- sees valid Lua instead of Chinese keywords, giving correct completions,
-- type checking and hover without any suppressed diagnostics.

local KEYWORDS = {
    ["否则如果"] = "elseif",
    ["如果"]     = "if",
    ["那么"]     = "then",
    ["否则"]     = "else",
    ["结束"]     = "end",
    ["当"]       = "while",
    ["重复"]     = "repeat",
    ["直到"]     = "until",
    ["对于"]     = "for",
    ["在"]       = "in",
    ["做"]       = "do",
    ["函数"]     = "function",
    ["返回"]     = "return",
    ["本地"]     = "local",
    ["真"]       = "true",
    ["假"]       = "false",
    ["空"]       = "nil",
    ["和"]       = "and",
    ["或"]       = "or",
    ["非"]       = "not",
    ["中断"]     = "break",
}

local function utf8_len(text, pos)
    local b = text:byte(pos) or 0
    if b < 0x80 then return 1
    elseif b < 0xE0 then return 2
    elseif b < 0xF0 then return 3
    else return 4 end
end

local function is_cjk(text, pos)
    local ok, cp = pcall(utf8.codepoint, text, pos)
    return ok and cp >= 0x4E00 and cp <= 0x9FFF
end

local function transpile(text)
    local out = {}
    local i   = 1
    local n   = #text

    while i <= n do
        local b = text:byte(i)

        -- Line or long comment: --
        if text:sub(i, i+1) == "--" then
            local long_open = text:match("^%[=*%[", i+2)
            if long_open then
                local close   = "]" .. ("="):rep(#long_open - 2) .. "]"
                local e       = text:find(close, i + 2 + #long_open, true)
                local end_pos = e and (e + #close - 1) or n
                out[#out+1]   = text:sub(i, end_pos)
                i = end_pos + 1
            else
                local e     = text:find("\n", i, true) or n + 1
                out[#out+1] = text:sub(i, e - 1)
                i = e
            end

        -- Short string: " or '
        elseif b == 34 or b == 39 then
            local j = i + 1
            while j <= n do
                local c = text:byte(j)
                if     c == 92 then j = j + 2   -- backslash escape
                elseif c == b  then j = j + 1; break
                else               j = j + 1 end
            end
            out[#out+1] = text:sub(i, j - 1)
            i = j

        -- Long string: [[ [=[ etc.
        elseif b == 91 then
            local long_open = text:match("^%[=*%[", i)
            if long_open then
                local close   = "]" .. ("="):rep(#long_open - 2) .. "]"
                local e       = text:find(close, i + #long_open, true)
                local end_pos = e and (e + #close - 1) or n
                out[#out+1]   = text:sub(i, end_pos)
                i = end_pos + 1
            else
                out[#out+1] = "["
                i = i + 1
            end

        -- Multi-byte UTF-8: accumulate consecutive CJK chars as one token
        elseif b >= 0x80 then
            if is_cjk(text, i) then
                local j = i
                while j <= n and is_cjk(text, j) do
                    j = j + utf8_len(text, j)
                end
                local word  = text:sub(i, j - 1)
                out[#out+1] = KEYWORDS[word] or word
                i = j
            else
                local len   = utf8_len(text, i)
                out[#out+1] = text:sub(i, i + len - 1)
                i = i + len
            end

        -- Plain ASCII
        else
            out[#out+1] = text:sub(i, i)
            i = i + 1
        end
    end

    return table.concat(out)
end

function OnSetText(uri, text)
    if uri:sub(-6) == ".luacn" then
        local ok, result = pcall(transpile, text)
        if ok then return result end
    end
    return text
end
