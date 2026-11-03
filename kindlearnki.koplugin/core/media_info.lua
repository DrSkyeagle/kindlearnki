--[[--
Natural pixel size of a media file, for the image zoom setting.

MuPDF lays an image out at 72 dpi while its pixels are taken to be 96 dpi, so a
600 px wide photo lands on the page as 450 px wide.  `img { zoom: 1.5 }` is
ignored by MuPDF (measured on the firmware build), so the only way to scale an
image is to give it an explicit width in CSS pixels -- and that width has to be
computed from the image's natural size, which is what this module reads.

Only the file header is touched (4 KiB), and every answer is cached: a card is
rebuilt on every page turn, and the Kindle's storage is slow.
]]

local MediaInfo = {}

local cache = {}
local HEAD_BYTES = 4096

local function byte(s, i)
    return string.byte(s, i) or 0
end

local function u16be(s, i)
    return byte(s, i) * 256 + byte(s, i + 1)
end

local function u16le(s, i)
    return byte(s, i + 1) * 256 + byte(s, i)
end

local function u24le(s, i)
    return byte(s, i) + byte(s, i + 1) * 256 + byte(s, i + 2) * 65536
end

local function u32be(s, i)
    return byte(s, i) * 16777216 + byte(s, i + 1) * 65536
        + byte(s, i + 2) * 256 + byte(s, i + 3)
end

local function u32le(s, i)
    return byte(s, i + 3) * 16777216 + byte(s, i + 2) * 65536
        + byte(s, i + 1) * 256 + byte(s, i)
end

local function png(head)
    if head:sub(1, 8) ~= "\137PNG\r\n\26\n" then
        return nil
    end
    if head:sub(13, 16) ~= "IHDR" then
        return nil
    end
    return u32be(head, 17), u32be(head, 21)
end

local function gif(head)
    local signature = head:sub(1, 6)
    if signature ~= "GIF87a" and signature ~= "GIF89a" then
        return nil
    end
    return u16le(head, 7), u16le(head, 9)
end

-- JPEG: walk the markers until a start-of-frame, whose payload carries the
-- picture size.  `0xC4/0xC8/0xCC` are Huffman/arithmetic tables, not frames.
local function jpeg(head)
    if head:sub(1, 2) ~= "\255\216" then
        return nil
    end
    local i = 3
    local length = #head
    while i + 3 <= length do
        if byte(head, i) ~= 0xFF then
            i = i + 1
        else
            local marker = byte(head, i + 1)
            if marker == 0xFF then
                i = i + 1
            elseif marker == 0xD8 or marker == 0x01
                or (marker >= 0xD0 and marker <= 0xD7) then
                i = i + 2
            elseif marker >= 0xC0 and marker <= 0xCF
                and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                return u16be(head, i + 7), u16be(head, i + 5)
            else
                local size = u16be(head, i + 2)
                if size < 2 then
                    return nil
                end
                i = i + 2 + size
            end
        end
    end
    return nil
end

local function webp(head)
    if head:sub(1, 4) ~= "RIFF" or head:sub(9, 12) ~= "WEBP" then
        return nil
    end
    local kind = head:sub(13, 16)
    if kind == "VP8 " then
        if head:sub(24, 26) ~= "\157\001\042" then
            return nil
        end
        return u16le(head, 27) % 16384, u16le(head, 29) % 16384
    elseif kind == "VP8L" then
        if byte(head, 21) ~= 0x2F then
            return nil
        end
        local bits = u32le(head, 22)
        return (bits % 16384) + 1, (math.floor(bits / 16384) % 16384) + 1
    elseif kind == "VP8X" then
        return u24le(head, 25) + 1, u24le(head, 28) + 1
    end
    return nil
end

local function bmp(head)
    if head:sub(1, 2) ~= "BM" then
        return nil
    end
    local width = u32le(head, 19)
    local height = u32le(head, 23)
    if width > 0x7FFFFFFF then
        width = 4294967296 - width
    end
    if height > 0x7FFFFFFF then
        height = 4294967296 - height
    end
    return width, height
end

local READERS = { png, gif, jpeg, webp, bmp }

local function read_head(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local head = file:read(HEAD_BYTES)
    file:close()
    return head
end

--- Natural size of an image file.
-- @tparam string path absolute path
-- @treturn number|nil width in pixels
-- @treturn number|nil height in pixels
function MediaInfo.measure(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local cached = cache[path]
    if cached ~= nil then
        if cached == false then
            return nil
        end
        return cached[1], cached[2]
    end
    local head = read_head(path)
    if not head or #head < 32 then
        -- Deliberately *not* cached: the media folder is filled in by the user
        -- (over USB, after the first render), and a remembered miss would leave
        -- that picture unscaled until the next restart.  A miss costs one
        -- `open`, which is cheap next to reading the header again.
        return nil
    end
    for _, reader in ipairs(READERS) do
        local width, height = reader(head)
        if width and height and width > 0 and height > 0 then
            cache[path] = { width, height }
            return width, height
        end
    end
    return nil
end

--- Forget every measurement (tests only).
function MediaInfo.reset()
    cache = {}
end

return MediaInfo
