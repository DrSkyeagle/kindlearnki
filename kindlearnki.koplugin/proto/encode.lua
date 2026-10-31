-- Minimal protobuf *encoder*, used only to patch deck counters in place.
--
-- The plugin otherwise never writes protobuf, but v3 keeps "new studied today"
-- and "reviews studied today" inside `decks.common` (decks.proto
-- Deck.Common.last_day_studied/new_studied/review_studied).  Re-encoding the
-- whole blob is safe because the decoded message keeps every unknown field,
-- including `other` (255), which newer Anki versions use for forward
-- compatibility.

local PB = require("proto.pb")

local Encode = {}

function Encode.varint(value)
    local out = {}
    local remaining = math.max(0, math.floor(value))
    repeat
        local byte = remaining % 128
        remaining = math.floor(remaining / 128)
        if remaining > 0 then
            byte = byte + 128
        end
        out[#out + 1] = string.char(byte)
    until remaining == 0
    return table.concat(out)
end

local function encode_varint_field(field, value)
    return Encode.varint(field * 8) .. Encode.varint(value)
end

local function encode_length_field(field, value)
    return Encode.varint(field * 8 + 2) .. Encode.varint(#value) .. value
end

--- Replace (or add) one varint field, keeping every other field verbatim.
function Encode.set_varint(message, field, value)
    message[field] = { { wire = 0, value = math.floor(value) } }
end

--- Serialise a decoded message back to bytes, in field-number order.
function Encode.encode(message)
    local fields = {}
    for field in pairs(message) do
        fields[#fields + 1] = field
    end
    table.sort(fields)

    local parts = {}
    for _, field in ipairs(fields) do
        for _, entry in ipairs(message[field]) do
            if entry.wire == 0 then
                parts[#parts + 1] = encode_varint_field(field, entry.value)
            elseif entry.wire == 2 then
                parts[#parts + 1] = encode_length_field(field, entry.value)
            end
            -- fixed32/fixed64 fields are not used by the messages we patch; if
            -- one ever appears it is dropped rather than mis-encoded, which is
            -- why this function is only called for Deck.Common.
        end
    end
    return table.concat(parts)
end

return Encode
