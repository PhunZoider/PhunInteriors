-- ---------------------------------------------------------------------------
-- JSON, vendored from PhunMart2 (shared/PhunMart/json.lua) unchanged except
-- for the pretty printer below.
--
-- Vendored rather than depended on, because this mod has no hard dependencies
-- and is not going to grow one for two hundred lines of parser. The copy is
-- deliberate duplication: if PhunMart's fixes a bug, this one has to be told.
--
-- WHY THERE IS JSON HERE AT ALL. CLAUDE.md used to say there is no file
-- reading at runtime and no json, and that was true while the registry was
-- only ever code. The admin editor writes what an admin changed, and the only
-- format a B42 runtime can read back is this one: B42.20.4 removed loadstring,
-- load and loadfile, so the "write a lua table, read it back with loadstring"
-- round trip PhunMart used to do no longer completes. It does not error --
-- loadstring is simply nil -- so the failure mode is an override file that
-- silently reads back as nothing. Author.emit still writes lua, and that is
-- fine: the game loads it as a mod file at boot, not through loadstring.
--
-- THE TRAP, and it is ours rather than the parser's: object keys must be
-- strings, and encodeValue ERRORS on anything else rather than coercing. That
-- is correct and deliberate -- a number key written out as a string comes back
-- as a string, so the next lookup by number misses it and quietly creates a
-- second record beside the first. It matters here because `locations` is
-- keyed by SLOT INDEX, sparse, starting at zero, and the index is the identity
-- a lease persists. So the store converts those keys to strings on the way out
-- and back to numbers on the way in, in one place, rather than letting each
-- caller remember. See overrides.lua.
-- ---------------------------------------------------------------------------

local json = {}

local function escapeString(value)
    local escapes = {
        ['\\'] = '\\\\',
        ['"'] = '\\"',
        ['\b'] = '\\b',
        ['\f'] = '\\f',
        ['\n'] = '\\n',
        ['\r'] = '\\r',
        ['\t'] = '\\t'
    }
    return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
        return escapes[char] or string.format('\\u%04x', string.byte(char))
    end) .. '"'
end

local function isArray(value)
    local count = 0
    for key in pairs(value) do
        if type(key) ~= 'number' or key < 1 or key ~= math.floor(key) then
            return false, 0
        end
        count = count + 1
    end
    for index = 1, count do
        if value[index] == nil then
            return false, 0
        end
    end
    return true, count
end

local function encodeValue(value, stack)
    local valueType = type(value)
    if value == nil then
        return 'null'
    elseif valueType == 'boolean' then
        return value and 'true' or 'false'
    elseif valueType == 'number' then
        if value ~= value or value == math.huge or value == -math.huge then
            error('cannot encode NaN or infinity')
        end
        return tostring(value)
    elseif valueType == 'string' then
        return escapeString(value)
    elseif valueType ~= 'table' then
        error('cannot encode ' .. valueType)
    end

    if stack[value] then
        error('cannot encode a circular table')
    end
    stack[value] = true

    local array, count = isArray(value)
    local result = {}
    if array then
        for index = 1, count do
            result[index] = encodeValue(value[index], stack)
        end
        stack[value] = nil
        return '[' .. table.concat(result, ',') .. ']'
    end

    for key, item in pairs(value) do
        if type(key) ~= 'string' then
            -- The offending key is named because the alternative is being told
            -- that something somewhere in a nested table is wrong and having to
            -- go looking for it.
            --
            -- Deliberately an error rather than a tostring() coercion. A number
            -- key written out as a string comes back as a string, so the next
            -- lookup by number misses it and quietly creates a second record
            -- beside the first. Losing the data slowly is worse than refusing
            -- to write it.
            error('object keys must be strings, got ' .. type(key) .. ' (' .. tostring(key) .. ')')
        end
        result[#result + 1] = escapeString(key) .. ':' .. encodeValue(item, stack)
    end
    stack[value] = nil
    return '{' .. table.concat(result, ',') .. '}'
end

function json.encode(value)
    local ok, result = pcall(encodeValue, value, {})
    if not ok then
        return nil, result
    end
    return result, nil
end

local function decodeError(message, position)
    error(message .. ' at character ' .. tostring(position))
end

local function decoder(source)
    local position = 1
    local length = #source

    local function skipWhitespace()
        while position <= length and source:sub(position, position):match('%s') do
            position = position + 1
        end
    end

    local parseValue

    local function parseString()
        position = position + 1
        local result = {}
        while position <= length do
            local char = source:sub(position, position)
            position = position + 1
            if char == '"' then
                return table.concat(result)
            elseif char == '\\' then
                local escaped = source:sub(position, position)
                position = position + 1
                local replacements = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
                if replacements[escaped] then
                    result[#result + 1] = replacements[escaped]
                elseif escaped == 'u' then
                    local hex = source:sub(position, position + 3)
                    if not hex:match('^%x%x%x%x$') then
                        decodeError('invalid unicode escape', position)
                    end
                    local code = tonumber(hex, 16)
                    position = position + 4
                    if code < 128 then
                        result[#result + 1] = string.char(code)
                    elseif code < 2048 then
                        result[#result + 1] = string.char(192 + math.floor(code / 64), 128 + code % 64)
                    else
                        result[#result + 1] = string.char(224 + math.floor(code / 4096), 128 + math.floor(code / 64) % 64, 128 + code % 64)
                    end
                else
                    decodeError('invalid string escape', position - 1)
                end
            else
                if string.byte(char) < 32 then
                    decodeError('control character in string', position - 1)
                end
                result[#result + 1] = char
            end
        end
        decodeError('unterminated string', position)
    end

    local function parseNumber()
        local start = position
        -- Scan to the end of the number, then let tonumber judge it.
        --
        -- This was a PCRE pattern: '^-?(?:0|[1-9]%d*)(?:%.%d+)?(?:[eE][+-]?%d+)?'.
        -- Lua patterns have no alternation and no non-capturing groups, so Lua
        -- read "(?" as a capture whose first item is a literal question mark.
        -- The pattern therefore demanded a "?" where the digits were and could
        -- never match a number at all, which meant every JSON file carrying one
        -- failed to decode. The failure was invisible: json.decode pcalls the
        -- decoder and returns nil plus a message, loadTable prints it and
        -- returns nil, so a saved config was silently thrown away on load.
        local finish = source:find('[^%-%+%d%.eE]', position) or (length + 1)
        local token = source:sub(position, finish - 1)
        local value = tonumber(token)
        if not value then
            decodeError('invalid number', start)
        end
        position = finish
        return value
    end

    local function parseArray()
        position = position + 1
        local result = {}
        skipWhitespace()
        if source:sub(position, position) == ']' then
            position = position + 1
            return result
        end
        while true do
            result[#result + 1] = parseValue()
            skipWhitespace()
            local char = source:sub(position, position)
            position = position + 1
            if char == ']' then
                return result
            elseif char ~= ',' then
                decodeError("expected ',' or ']'", position - 1)
            end
            skipWhitespace()
        end
    end

    local function parseObject()
        position = position + 1
        local result = {}
        skipWhitespace()
        if source:sub(position, position) == '}' then
            position = position + 1
            return result
        end
        while true do
            if source:sub(position, position) ~= '"' then
                decodeError('object key must be a string', position)
            end
            local key = parseString()
            skipWhitespace()
            if source:sub(position, position) ~= ':' then
                decodeError("expected ':'", position)
            end
            position = position + 1
            result[key] = parseValue()
            skipWhitespace()
            local char = source:sub(position, position)
            position = position + 1
            if char == '}' then
                return result
            elseif char ~= ',' then
                decodeError("expected ',' or '}'", position - 1)
            end
            skipWhitespace()
        end
    end

    parseValue = function()
        skipWhitespace()
        local char = source:sub(position, position)
        if char == '"' then return parseString() end
        if char == '{' then return parseObject() end
        if char == '[' then return parseArray() end
        if source:sub(position, position + 3) == 'true' then position = position + 4; return true end
        if source:sub(position, position + 4) == 'false' then position = position + 5; return false end
        if source:sub(position, position + 3) == 'null' then position = position + 4; return nil end
        if char == '-' or char:match('%d') then return parseNumber() end
        decodeError('unexpected token', position)
    end

    local result = parseValue()
    skipWhitespace()
    if position <= length then
        decodeError('trailing content', position)
    end
    return result
end

function json.decode(source)
    if type(source) ~= 'string' then
        return nil, 'JSON input must be a string'
    end
    local ok, result = pcall(decoder, source)
    if not ok then
        return nil, result
    end
    return result, nil
end

-- ---------------------------------------------------------------------------
-- Pretty printing, which PhunMart's copy does not do.
--
-- Its files are written by an editor and read by one. Ours is a config file an
-- admin is invited to open, diff and hand edit -- which is most of the reason
-- for putting it in the Lua folder rather than in GlobalModData -- and a room
-- set on one line is not something anybody can review. The cost is a larger
-- file, which at a few hundred rooms is still trivial next to the map.
--
-- Keys are sorted, so re-saving an unchanged file produces an identical one.
-- Without that, pairs() order decides the layout and every save is a full
-- diff, which is exactly the failure Author.emit sorts its locations to avoid.
-- ---------------------------------------------------------------------------

local function sortedKeys(t)
    local keys = {}
    for key in pairs(t) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

-- A pairs loop rather than `next(t) == nil`, which is how anybody would write
-- it and does not work here: PZ's Lua sandbox does not expose next(). LuaJIT
-- does, so this is one of the mistakes the test suite cannot catch -- it runs
-- clean outside the game and throws "attempt to call nil" inside it.
local function isEmptyTable(t)
    for _ in pairs(t) do
        return false
    end
    return true
end

-- Scalars are handed to the compact encoder rather than re-implemented.
-- Sharing the leaves is what stops the two disagreeing about how a string is
-- escaped, and escaping is the half that is easy to get subtly wrong twice.
local function encodePretty(value, indent, stack)
    if type(value) ~= "table" then
        local encoded, err = json.encode(value)
        if not encoded then
            error(err)
        end
        return encoded
    end

    if stack[value] then
        error("cannot encode a circular table")
    end
    stack[value] = true

    local pad = string.rep("  ", indent + 1)
    local closePad = string.rep("  ", indent)
    local array, count = isArray(value)
    local parts = {}

    -- Empty first, and deliberately "{}" rather than the "[]" isArray would
    -- have it be. An empty Lua table is both, and every empty table this mod
    -- writes is an object whose entries have all been removed -- a `requires`
    -- an admin cleared, a `locations` not yet filled in. A file that flipped
    -- those between {} and [] on alternate saves is a diff nobody can read.
    -- It costs nothing on the way back: [] and {} both decode to an empty Lua
    -- table, so this is the only place the two spellings differ.
    if isEmptyTable(value) then
        stack[value] = nil
        return "{}"
    end

    if array then
        for index = 1, count do
            parts[index] = pad .. encodePretty(value[index], indent + 1, stack)
        end
        stack[value] = nil
        return "[\n" .. table.concat(parts, ",\n") .. "\n" .. closePad .. "]"
    end

    local keys = sortedKeys(value)
    for i, key in ipairs(keys) do
        if type(key) ~= "string" then
            error("object keys must be strings, got " .. type(key) .. " (" .. tostring(key) .. ")")
        end
        parts[i] = pad .. escapeString(key) .. ": " .. encodePretty(value[key], indent + 1, stack)
    end
    stack[value] = nil
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. closePad .. "}"
end

--- Same contract as json.encode -- text, or nil plus a message -- laid out.
function json.encodePretty(value)
    local ok, result = pcall(encodePretty, value, 0, {})
    if not ok then
        return nil, result
    end
    return result, nil
end

return json
