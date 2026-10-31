--[[--
Minimal JSON codec for the AnkiWeb sync wire format.

Why hand-written instead of KOReader's `rapidjson` or a vendored library:

  * this layer must load on a bare LuaJIT (the L1 test runner) with no
    KOReader tree at all, so it cannot depend on a host module;
  * sync bodies are tiny (a chunk is at most 250 rows), so LuaJIT is plenty
    fast, and the whole codec stays unit-testable off-device;
  * the wire rules are narrower than "any JSON": anki's field separator
    (0x1F) must be escaped, empty *arrays* and empty *objects* must be
    distinguishable, and non-finite numbers must never reach the peer.

Encoding rules:

  * an empty table encodes as `{}`; use `json.array()` / `json.array{}` when
    the peer expects `[]` and `json.object()` when it expects `{}`;
  * a table whose keys are exactly 1..n encodes as an array, anything else
    (holes, string keys, mixed) as an object;
  * non-ASCII UTF-8 bytes pass through verbatim -- Chinese/Japanese must not
    be escaped to `\uXXXX`, both because it bloats every note and because
    anki compares some strings byte-for-byte;
  * NaN and +-Inf raise: emitting `nan`/`inf` would produce a body that
    Python's `json` (and serde) reject, and the failure would surface far
    away from its cause;
  * object keys are sorted so output is deterministic for tests. The
    protocol does not require key order.

Decoding rules:

  * JSON `null` decodes to `nil`; array positions that held null keep their
    index (holes), so `[[0,0,0],1]` keeps its shape;
  * decoded arrays are marked so re-encoding an empty one yields `[]`;
  * numbers decode to Lua numbers (double). Every integer the sync protocol
    carries -- millisecond timestamps, card/note ids -- is below 2^53, so
    doubles are exact;
  * malformed input raises an error with a byte offset; callers that parse
    remote data wrap the call in pcall.

@module sync.json
]]

local M = {}

--- Sentinel that encodes as JSON `null`. Lua cannot store nil in a table, so
--- a table field that must be explicitly null needs this marker.
local NULL = setmetatable({}, {
    __tostring = function()
        return "null"
    end,
})
M.null = NULL

local ARRAY_MT = { __jsontype = "array" }
local OBJECT_MT = { __jsontype = "object" }

--[[-- Explicit array lengths for decoded arrays.
--
-- Lua's `#` is a *border*, not a length: after decoding `[1,null,3]` the
-- table is `{[1]=1,[3]=3}` and `#` may answer 1, which would silently drop
-- the trailing elements on re-encode. JSON nulls are legal in arrays, and a
-- response should round-trip byte-for-byte even when one appears, so decoded
-- arrays record their real length here. Weak keys: the entry disappears with
-- the array, and nothing is visible to callers iterating the table. ]]
local array_lengths = setmetatable({}, { __mode = "k" })

--- Force a table to encode as a JSON array (needed for empty arrays).
function M.array(tbl)
    return setmetatable(tbl or {}, ARRAY_MT)
end

--- Force a table to encode as a JSON object (needed for empty objects).
function M.object(tbl)
    return setmetatable(tbl or {}, OBJECT_MT)
end

--- True when `value` is the explicit-null sentinel. Callers use this to
--- treat a sentinel coming from hand-built tables like a decoded nil.
function M.is_null(value)
    return value == NULL
end

--==========================================================================
-- Encoding
--==========================================================================

local SIMPLE_ESCAPES = {
    ['"'] = '\\"',
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

-- Control bytes must be escaped; bytes >= 0x80 are UTF-8 continuation bytes
-- and pass through untouched.
local function escape_string(value)
    local escaped = value:gsub('[%z\1-\31"\\]', function(char)
        local known = SIMPLE_ESCAPES[char]
        if known then
            return known
        end
        return string.format("\\u%04x", char:byte())
    end)
    return '"' .. escaped .. '"'
end

local function encode_number(number)
    if number ~= number or number == math.huge or number == -math.huge then
        error("json: 无法编码 NaN 或无穷大（非有限数字）", 0)
    end
    -- Integral values print without a decimal point; AnkiWeb's serde types
    -- for ids/usn are integers, and `1.0` would deserialize into some of them
    -- but not all.
    if number == math.floor(number) and math.abs(number) < 9007199254740992 then
        return string.format("%d", number)
    end
    -- Shortest representation that round-trips through a double. Fixed %.17g
    -- is exact but turns 0.1 into 0.10000000000000001, which is needlessly
    -- noisy in a protocol log.
    for _, format in ipairs({ "%.15g", "%.16g", "%.17g" }) do
        local text = string.format(format, number)
        if tonumber(text) == number then
            return text
        end
    end
    return string.format("%.17g", number)
end

--- True when the table has exactly the integer keys 1..n (n > 0).
local function is_dense_array(value)
    local metatable = getmetatable(value)
    if metatable == ARRAY_MT then
        return true
    elseif metatable == OBJECT_MT then
        return false
    end
    local count, max_index = 0, 0
    for key, item in pairs(value) do
        if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then
            return false
        end
        if item == nil then
            return false
        end
        count = count + 1
        if key > max_index then
            max_index = key
        end
    end
    return count > 0 and count == max_index
end

local function ordered_keys(value)
    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(left, right)
        local left_type, right_type = type(left), type(right)
        if left_type ~= right_type then
            -- Deterministic: numbers first, then strings.
            return left_type < right_type
        end
        return left < right
    end)
    return keys
end

local encode_value

local function encode_table(value, out)
    if is_dense_array(value) then
        out[#out + 1] = "["
        local length = math.max(array_lengths[value] or 0, #value)
        for index = 1, length do
            if index > 1 then
                out[#out + 1] = ","
            end
            encode_value(value[index], out)
        end
        out[#out + 1] = "]"
        return
    end

    out[#out + 1] = "{"
    local first = true
    for _, key in ipairs(ordered_keys(value)) do
        local key_type = type(key)
        if key_type ~= "string" and key_type ~= "number" then
            error("json: 对象键必须是字符串或数字，实际为 " .. key_type, 0)
        end
        if not first then
            out[#out + 1] = ","
        end
        first = false
        out[#out + 1] = escape_string(tostring(key))
        out[#out + 1] = ":"
        encode_value(value[key], out)
    end
    out[#out + 1] = "}"
end

encode_value = function(value, out)
    if value == nil or value == NULL then
        out[#out + 1] = "null"
        return
    end
    local value_type = type(value)
    if value_type == "boolean" then
        out[#out + 1] = value and "true" or "false"
    elseif value_type == "number" then
        out[#out + 1] = encode_number(value)
    elseif value_type == "string" then
        out[#out + 1] = escape_string(value)
    elseif value_type == "table" then
        encode_table(value, out)
    else
        error("json: 无法编码类型 " .. value_type, 0)
    end
end

--- Encode a Lua value into a JSON document.
-- @return string
function M.encode(value)
    local parts = {}
    encode_value(value, parts)
    return table.concat(parts)
end

--==========================================================================
-- Decoding
--==========================================================================

local function decode_error(text, position, message)
    error(string.format("json: %s（位置 %d，附近 %q）", message, position,
        text:sub(position, position + 16)), 0)
end

local function skip_whitespace(text, position)
    local _, last = text:find("^[ \t\r\n]*", position)
    return (last or position - 1) + 1
end

local function utf8_char(codepoint)
    if codepoint < 0x80 then
        return string.char(codepoint)
    elseif codepoint < 0x800 then
        return string.char(0xC0 + math.floor(codepoint / 0x40),
            0x80 + codepoint % 0x40)
    elseif codepoint < 0x10000 then
        return string.char(0xE0 + math.floor(codepoint / 0x1000),
            0x80 + math.floor(codepoint / 0x40) % 0x40,
            0x80 + codepoint % 0x40)
    end
    return string.char(0xF0 + math.floor(codepoint / 0x40000),
        0x80 + math.floor(codepoint / 0x1000) % 0x40,
        0x80 + math.floor(codepoint / 0x40) % 0x40,
        0x80 + codepoint % 0x40)
end

local SIMPLE_UNESCAPES = {
    ['"'] = '"',
    ["\\"] = "\\",
    ["/"] = "/",
    ["b"] = "\b",
    ["f"] = "\f",
    ["n"] = "\n",
    ["r"] = "\r",
    ["t"] = "\t",
}

local decode_value

-- A JSON string must not contain raw control bytes; they are only legal as
-- escapes. Finding them here means the payload is broken.
local STRING_SPECIALS = '["\\%z\1-\31]'

local function decode_string(text, position)
    local parts, index = {}, position + 1
    while true do
        local special = text:find(STRING_SPECIALS, index)
        if not special then
            decode_error(text, index, "字符串没有结束引号")
        end
        if special > index then
            parts[#parts + 1] = text:sub(index, special - 1)
        end
        local char = text:sub(special, special)
        if char == '"' then
            return table.concat(parts), special + 1
        end
        if char ~= "\\" then
            decode_error(text, special,
                "字符串中含未转义的控制字符（需写成 \\u00XX）")
        end

        local escape = text:sub(special + 1, special + 1)
        local simple = SIMPLE_UNESCAPES[escape]
        if simple then
            parts[#parts + 1] = simple
            index = special + 2
        elseif escape == "u" then
            local hex = text:sub(special + 2, special + 5)
            if not hex:match("^%x%x%x%x$") then
                decode_error(text, special, "非法的 \\u 转义")
            end
            local codepoint = tonumber(hex, 16)
            index = special + 6
            if codepoint >= 0xD800 and codepoint <= 0xDBFF then
                -- High surrogate: a low surrogate must follow for a valid
                -- pair. A lone surrogate is replaced rather than rejected:
                -- anki fields are user text, and refusing the whole payload
                -- over one bad code point would block the sync entirely.
                local low_hex = text:sub(index + 2, index + 5)
                local low = text:sub(index, index + 1) == "\\u"
                    and tonumber(low_hex, 16)
                if low and low >= 0xDC00 and low <= 0xDFFF then
                    codepoint = 0x10000
                        + (codepoint - 0xD800) * 0x400
                        + (low - 0xDC00)
                    index = index + 6
                else
                    codepoint = 0xFFFD
                end
            elseif codepoint >= 0xDC00 and codepoint <= 0xDFFF then
                codepoint = 0xFFFD
            end
            parts[#parts + 1] = utf8_char(codepoint)
        else
            decode_error(text, special, "非法的转义序列 \\" .. tostring(escape))
        end
    end
end

local function decode_number(text, position)
    local char = text:sub(position, position)
    if char ~= "-" and not char:match("%d") then
        decode_error(text, position, "非法的数字")
    end
    local _, last = text:find("^-?%d+", position)
    if not last then
        decode_error(text, position, "非法的数字")
    end
    local after = last + 1
    if text:sub(after, after) == "." then
        local _, fraction_end = text:find("^%d+", after + 1)
        if not fraction_end then
            decode_error(text, position, "小数点后缺少数字")
        end
        after = fraction_end + 1
    end
    if text:sub(after, after):match("[eE]") then
        local _, exponent_end = text:find("^[eE][-+]?%d+", after)
        if not exponent_end then
            decode_error(text, position, "指数部分不完整")
        end
        after = exponent_end + 1
    end

    local number = tonumber(text:sub(position, after - 1))
    if not number or number ~= number
        or number == math.huge or number == -math.huge then
        decode_error(text, position, "非有限数字")
    end
    return number, after
end

local function decode_array(text, position)
    -- Mark the table even though it may start out empty: an empty array
    -- decoded from the wire must re-encode as `[]`, not `{}`.
    local out, index = setmetatable({}, ARRAY_MT), position + 1
    local count = 0
    index = skip_whitespace(text, index)
    if text:sub(index, index) == "]" then
        array_lengths[out] = 0
        return out, index + 1
    end
    while true do
        index = skip_whitespace(text, index)
        local value
        value, index = decode_value(text, index)
        count = count + 1
        if value ~= nil then
            out[count] = value
        end
        index = skip_whitespace(text, index)
        local char = text:sub(index, index)
        if char == "," then
            index = index + 1
        elseif char == "]" then
            array_lengths[out] = count
            return out, index + 1
        else
            decode_error(text, index, "数组元素之间缺少逗号")
        end
    end
end

local function decode_object(text, position)
    local out, index = {}, position + 1
    index = skip_whitespace(text, index)
    if text:sub(index, index) == "}" then
        return out, index + 1
    end
    while true do
        index = skip_whitespace(text, index)
        if text:sub(index, index) ~= '"' then
            decode_error(text, index, "对象的键必须是字符串")
        end
        local key
        key, index = decode_string(text, index)
        index = skip_whitespace(text, index)
        if text:sub(index, index) ~= ":" then
            decode_error(text, index, "键后面缺少冒号")
        end
        index = skip_whitespace(text, index + 1)
        local value
        value, index = decode_value(text, index)
        out[key] = value
        index = skip_whitespace(text, index)
        local char = text:sub(index, index)
        if char == "," then
            index = index + 1
        elseif char == "}" then
            return out, index + 1
        else
            decode_error(text, index, "对象成员之间缺少逗号")
        end
    end
end

decode_value = function(text, position)
    local char = text:sub(position, position)
    if char == "" then
        decode_error(text, position, "内容意外结束")
    elseif char == '"' then
        return decode_string(text, position)
    elseif char == "{" then
        return decode_object(text, position)
    elseif char == "[" then
        return decode_array(text, position)
    elseif text:sub(position, position + 3) == "true" then
        return true, position + 4
    elseif text:sub(position, position + 4) == "false" then
        return false, position + 5
    elseif text:sub(position, position + 3) == "null" then
        return nil, position + 4
    elseif char == "-" or char:match("%d") then
        return decode_number(text, position)
    end
    decode_error(text, position, "无法识别的字符")
end

--- Decode a complete JSON document.
--
-- Trailing non-whitespace bytes are an error: a stream reader that stops at
-- the first value would silently accept a truncated/garbled body.
-- @treturn any decoded value (JSON null becomes nil)
function M.decode(text)
    if type(text) ~= "string" then
        error("json.decode 需要字符串，实际为 " .. type(text), 0)
    end
    local position = skip_whitespace(text, 1)
    local value, after = decode_value(text, position)
    after = skip_whitespace(text, after)
    if after <= #text then
        decode_error(text, after, "JSON 文档结束后还有多余内容")
    end
    return value
end

return M
