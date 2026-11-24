-- Portable Characters: a small JSON reader and writer for the character files.
-- (The game lets Lua write .json, .txt, .ini, .cfg and .log files under Zomboid/Lua, and has no
-- JSON of its own for mods.)

require "PortableCharacters/PC_Core"

local PC = PortableCharacters
local Json = {}
PC.Json = Json

local HEX = "0123456789abcdef"

local function hex4(code)
    local out = ""
    for _ = 1, 4 do
        local digit = code % 16
        out = string.sub(HEX, digit + 1, digit + 1) .. out
        code = (code - digit) / 16
    end
    return out
end

local function encodeString(s)
    if not string.find(s, '[%c"\\]') then
        return '"' .. s .. '"'
    end
    local parts = { '"' }
    for i = 1, #s do
        local c = string.sub(s, i, i)
        local code = string.byte(c)
        if c == '"' then
            parts[#parts + 1] = '\\"'
        elseif c == "\\" then
            parts[#parts + 1] = "\\\\"
        elseif c == "\n" then
            parts[#parts + 1] = "\\n"
        elseif c == "\r" then
            parts[#parts + 1] = "\\r"
        elseif c == "\t" then
            parts[#parts + 1] = "\\t"
        elseif code < 32 then
            parts[#parts + 1] = "\\u" .. hex4(code)
        else
            parts[#parts + 1] = c
        end
    end
    parts[#parts + 1] = '"'
    return table.concat(parts)
end

local function isArray(t)
    local n = #t
    if n == 0 then
        return false
    end
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count == n
end

local function encodeValue(v, parts)
    local kind = type(v)
    if kind == "table" then
        if isArray(v) then
            parts[#parts + 1] = "["
            for i = 1, #v do
                if i > 1 then
                    parts[#parts + 1] = ","
                end
                encodeValue(v[i], parts)
            end
            parts[#parts + 1] = "]"
        else
            parts[#parts + 1] = "{"
            local first = true
            for key, value in pairs(v) do
                local valueKind = type(value)
                if valueKind == "table" or valueKind == "string" or valueKind == "number" or valueKind == "boolean" then
                    if not first then
                        parts[#parts + 1] = ","
                    end
                    first = false
                    parts[#parts + 1] = encodeString(tostring(key))
                    parts[#parts + 1] = ":"
                    encodeValue(value, parts)
                end
            end
            parts[#parts + 1] = "}"
        end
    elseif kind == "string" then
        parts[#parts + 1] = encodeString(v)
    elseif kind == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            parts[#parts + 1] = "0"
        elseif v == math.floor(v) and v > -1e15 and v < 1e15 then
            parts[#parts + 1] = string.format("%d", v)
        else
            parts[#parts + 1] = tostring(v)
        end
    elseif kind == "boolean" then
        parts[#parts + 1] = v and "true" or "false"
    else
        parts[#parts + 1] = "null"
    end
end

function Json.encode(value)
    local parts = {}
    encodeValue(value, parts)
    return table.concat(parts)
end

-- Reading -------------------------------------------------------------------------------------

local B_SPACE, B_TAB, B_LF, B_CR = 32, 9, 10, 13
local B_QUOTE, B_BACKSLASH = 34, 92
local B_LBRACE, B_RBRACE, B_LBRACKET, B_RBRACKET = 123, 125, 91, 93
local B_COMMA, B_COLON = 44, 58

local decodeValue

local function skipSpace(s, i)
    while true do
        local b = string.byte(s, i)
        if b == B_SPACE or b == B_TAB or b == B_LF or b == B_CR then
            i = i + 1
        else
            return i
        end
    end
end

local function decodeString(s, i)
    -- s[i] is the opening quote
    local parts = nil
    local start = i + 1
    local pos = start
    while true do
        local found = string.find(s, '["\\]', pos)
        if not found then
            error("unterminated string")
        end
        if string.byte(s, found) == B_QUOTE then
            local tail = string.sub(s, start, found - 1)
            if parts then
                parts[#parts + 1] = tail
                return table.concat(parts), found + 1
            end
            return tail, found + 1
        end
        parts = parts or {}
        parts[#parts + 1] = string.sub(s, start, found - 1)
        local esc = string.sub(s, found + 1, found + 1)
        if esc == "n" then
            parts[#parts + 1] = "\n"
            pos = found + 2
        elseif esc == "r" then
            parts[#parts + 1] = "\r"
            pos = found + 2
        elseif esc == "t" then
            parts[#parts + 1] = "\t"
            pos = found + 2
        elseif esc == "u" then
            local code = tonumber(string.sub(s, found + 2, found + 5), 16) or 63
            parts[#parts + 1] = string.char(code)
            pos = found + 6
        else
            -- \" \\ \/ and anything unknown: keep the character itself
            parts[#parts + 1] = esc
            pos = found + 2
        end
        start = pos
    end
end

local function decodeNumber(s, i)
    local j = i
    while true do
        local b = string.byte(s, j)
        -- digits, + - . e E
        if b and ((b >= 48 and b <= 57) or b == 43 or b == 45 or b == 46 or b == 101 or b == 69) then
            j = j + 1
        else
            break
        end
    end
    local n = tonumber(string.sub(s, i, j - 1))
    if n == nil then
        error("bad number at " .. i)
    end
    return n, j
end

decodeValue = function(s, i)
    i = skipSpace(s, i)
    local b = string.byte(s, i)
    if b == B_LBRACE then
        local out = {}
        i = skipSpace(s, i + 1)
        if string.byte(s, i) == B_RBRACE then
            return out, i + 1
        end
        while true do
            i = skipSpace(s, i)
            if string.byte(s, i) ~= B_QUOTE then
                error("expected a key at " .. i)
            end
            local key
            key, i = decodeString(s, i)
            i = skipSpace(s, i)
            if string.byte(s, i) ~= B_COLON then
                error("expected ':' at " .. i)
            end
            local value
            value, i = decodeValue(s, i + 1)
            out[key] = value
            i = skipSpace(s, i)
            local sep = string.byte(s, i)
            if sep == B_COMMA then
                i = i + 1
            elseif sep == B_RBRACE then
                return out, i + 1
            else
                error("expected ',' or '}' at " .. i)
            end
        end
    elseif b == B_LBRACKET then
        local out = {}
        i = skipSpace(s, i + 1)
        if string.byte(s, i) == B_RBRACKET then
            return out, i + 1
        end
        while true do
            local value
            value, i = decodeValue(s, i)
            out[#out + 1] = value
            i = skipSpace(s, i)
            local sep = string.byte(s, i)
            if sep == B_COMMA then
                i = i + 1
            elseif sep == B_RBRACKET then
                return out, i + 1
            else
                error("expected ',' or ']' at " .. i)
            end
        end
    elseif b == B_QUOTE then
        return decodeString(s, i)
    elseif string.sub(s, i, i + 3) == "true" then
        return true, i + 4
    elseif string.sub(s, i, i + 4) == "false" then
        return false, i + 5
    elseif string.sub(s, i, i + 3) == "null" then
        return nil, i + 4
    else
        return decodeNumber(s, i)
    end
end

-- Gives the value, or nil and an error text.
function Json.decode(text)
    if type(text) ~= "string" or text == "" then
        return nil, "empty"
    end
    local ok, value = pcall(function()
        local result = decodeValue(text, 1)
        return result
    end)
    if ok then
        return value
    end
    return nil, tostring(value)
end

return Json
