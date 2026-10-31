-- Minimal protobuf reader.
--
-- The plugin only ever *reads* protobuf: notetype configs, template configs,
-- deck configs and deck kinds. Everything the wire protocol carries is JSON
-- (see doc/SYNC-SPEC.md), so there is no encoder here — writing protobuf would
-- be dead code with a maintenance cost.
--
-- Field numbers come from anki-26.09.3/proto/anki/*.proto. Unknown fields are
-- kept in the decoded table and never re-serialised, so a newer desktop build
-- cannot make us corrupt a collection.

local PB = {}

local function read_varint(s, pos)
    local result, shift = 0, 0
    while true do
        local byte = s:byte(pos)
        if not byte then
            return nil, pos
        end
        pos = pos + 1
        result = result + (byte % 128) * 2 ^ shift
        if byte < 128 then
            return result, pos
        end
        shift = shift + 7
        if shift > 63 then
            return nil, pos
        end
    end
end

local float_union
local function read_float(bytes)
    if not float_union then
        local ffi = require("ffi")
        ffi.cdef[[
            union kindlearnki_float_bits { uint32_t u; float f; };
        ]]
        float_union = ffi.new("union kindlearnki_float_bits")
    end
    local b1, b2, b3, b4 = bytes:byte(1, 4)
    float_union.u = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    return float_union.f
end

--- Decode one message into `{ [field] = { {wire=, value=}, ... } }`.
function PB.decode(s)
    local message = {}
    local pos = 1
    local length = #s
    while pos <= length do
        local key
        key, pos = read_varint(s, pos)
        if not key then
            break
        end
        local field = math.floor(key / 8)
        local wire = key % 8
        local value
        if wire == 0 then
            value, pos = read_varint(s, pos)
        elseif wire == 1 then
            value = s:sub(pos, pos + 7)
            pos = pos + 8
        elseif wire == 2 then
            local size
            size, pos = read_varint(s, pos)
            if not size then
                break
            end
            value = s:sub(pos, pos + size - 1)
            pos = pos + size
        elseif wire == 5 then
            value = s:sub(pos, pos + 3)
            pos = pos + 4
        else
            -- Groups (3/4) are not used by Anki's protos; stop rather than
            -- silently mis-parsing the rest of the blob.
            break
        end
        message[field] = message[field] or {}
        table.insert(message[field], { wire = wire, value = value })
    end
    return message
end

local function last(message, field)
    local entries = message and message[field]
    return entries and entries[#entries] or nil
end

function PB.has(message, field)
    return last(message, field) ~= nil
end

function PB.uint(message, field, default)
    local entry = last(message, field)
    if not entry or entry.wire ~= 0 then
        return default
    end
    return entry.value
end

function PB.int(message, field, default)
    return PB.uint(message, field, default)
end

function PB.bool(message, field, default)
    local value = PB.uint(message, field, nil)
    if value == nil then
        return default
    end
    return value ~= 0
end

function PB.string(message, field, default)
    local entry = last(message, field)
    if not entry or entry.wire ~= 2 then
        return default
    end
    return entry.value
end

function PB.bytes(message, field)
    local entry = last(message, field)
    if not entry or entry.wire ~= 2 then
        return nil
    end
    return entry.value
end

function PB.float(message, field, default)
    local entry = last(message, field)
    if not entry then
        return default
    end
    if entry.wire == 5 then
        return read_float(entry.value)
    end
    return default
end

function PB.repeated_float(message, field)
    local values = {}
    for _, entry in ipairs(message and message[field] or {}) do
        if entry.wire == 5 then
            values[#values + 1] = read_float(entry.value)
        elseif entry.wire == 2 then
            -- proto3 packs repeated scalars by default: field 1 arrives as one
            -- length-delimited blob of 4-byte floats.  Reading only wire-type 5
            -- silently produced empty learn/relearn steps.
            local packed = entry.value
            for offset = 1, #packed - 3, 4 do
                values[#values + 1] = read_float(packed:sub(offset, offset + 3))
            end
        end
    end
    return values
end

function PB.message(message, field)
    local entry = last(message, field)
    if not entry or entry.wire ~= 2 then
        return nil
    end
    return PB.decode(entry.value)
end

return PB
