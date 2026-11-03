--[[--
Header parsing for the image zoom setting.

The fixtures are hand-built headers, not real pictures: MuPDF never sees them,
only `MediaInfo.measure()` does, and the bytes below are exactly the part of
each format that carries the size.
]]

local Helpers = require("helpers")
local MediaInfo = require("core.media_info")

-- `out/tmp` is created by the runner; every fixture gets its own name so two
-- runs cannot see each other's files.
local TMP = Helpers.root .. "/../out/tmp"

local function write(name, bytes)
    local path = TMP .. "/mediainfo-" .. name
    local file = assert(io.open(path, "wb"), "cannot write " .. path)
    file:write(bytes)
    file:close()
    return path
end

local function be16(value)
    return string.char(math.floor(value / 256) % 256, value % 256)
end

local function be32(value)
    return string.char(
        math.floor(value / 16777216) % 256,
        math.floor(value / 65536) % 256,
        math.floor(value / 256) % 256,
        value % 256)
end

local function le32(value)
    return string.char(
        value % 256,
        math.floor(value / 256) % 256,
        math.floor(value / 65536) % 256,
        math.floor(value / 16777216) % 256)
end

local function le16(value)
    return string.char(value % 256, math.floor(value / 256) % 256)
end

--- PNG: signature, IHDR length/type, width, height, then filler.
local function png(width, height)
    return "\137PNG\r\n\26\n" .. be32(13) .. "IHDR"
        .. be32(width) .. be32(height) .. "\8\2\0\0\0"
        .. string.rep("\0", 40)
end

--- GIF: "GIF89a", logical screen width/height (little endian), then filler.
local function gif(width, height)
    return "GIF89a" .. le16(width) .. le16(height) .. "\0\0\0" .. string.rep("\0", 40)
end

--- JPEG: SOI, an APP0 segment, then SOF0 with the frame size.
--- Segment lengths are big-endian here, unlike the GIF/WebP/BMP fields.
local function jpeg(width, height)
    local app0 = "\255\224" .. be16(16) .. string.rep("\0", 14)
    local sof0 = "\255\192" .. be16(17) .. "\8" .. be16(height) .. be16(width)
        .. "\3" .. string.rep("\0", 9)
    return "\255\216" .. app0 .. sof0 .. "\255\217"
end

--- WebP (lossy): RIFF/WEBP, a VP8 chunk with the 0x9d 0x01 0x2a start code.
local function webp(width, height)
    return "RIFF" .. le32(100) .. "WEBP" .. "VP8 " .. le32(30)
        .. "\0\0\0" .. "\157\001\042" .. le16(width) .. le16(height)
        .. string.rep("\0", 20)
end

--- BMP: "BM", then the header fields Windows writes, width/height at 18/22.
local function bmp(width, height)
    return "BM" .. string.rep("\0", 16) .. le32(width) .. le32(height)
        .. string.rep("\0", 30)
end

return {
    ["PNG size comes from the IHDR chunk"] = function()
        MediaInfo.reset()
        local path = write("a.png", png(600, 400))
        local width, height = MediaInfo.measure(path)
        assert(width == 600 and height == 400, tostring(width) .. "x" .. tostring(height))
    end,

    ["GIF size comes from the logical screen descriptor"] = function()
        MediaInfo.reset()
        local path = write("a.gif", gif(1200, 800))
        local width, height = MediaInfo.measure(path)
        assert(width == 1200 and height == 800, tostring(width) .. "x" .. tostring(height))
    end,

    ["JPEG size comes from the start of frame, after the APP0 segment"] = function()
        MediaInfo.reset()
        local path = write("a.jpg", jpeg(1024, 768))
        local width, height = MediaInfo.measure(path)
        assert(width == 1024 and height == 768, tostring(width) .. "x" .. tostring(height))
    end,

    ["WebP size comes from the VP8 frame header"] = function()
        MediaInfo.reset()
        local path = write("a.webp", webp(500, 250))
        local width, height = MediaInfo.measure(path)
        assert(width == 500 and height == 250, tostring(width) .. "x" .. tostring(height))
    end,

    ["BMP size comes from the info header"] = function()
        MediaInfo.reset()
        local path = write("a.bmp", bmp(320, 200))
        local width, height = MediaInfo.measure(path)
        assert(width == 320 and height == 200, tostring(width) .. "x" .. tostring(height))
    end,

    ["an unknown file measures nothing instead of guessing"] = function()
        MediaInfo.reset()
        local path = write("a.bin", string.rep("\0", 64))
        assert(MediaInfo.measure(path) == nil)
    end,

    ["a missing file measures nothing"] = function()
        MediaInfo.reset()
        assert(MediaInfo.measure(TMP .. "/mediainfo-does-not-exist.png") == nil)
    end,

    ["a measurement is cached, and a failed one is not retried"] = function()
        MediaInfo.reset()
        local path = write("cached.png", png(640, 480))
        assert(MediaInfo.measure(path) == 640)
        -- Rewriting the file must not change the answer: a card is rebuilt on
        -- every page turn and must not stat the SD card each time.
        local file = assert(io.open(path, "wb"))
        file:write(png(10, 10))
        file:close()
        local width = MediaInfo.measure(path)
        assert(width == 640, tostring(width))
        MediaInfo.reset()
        assert(MediaInfo.measure(path) == 10)
    end,

    ["a missing file is measured as soon as it lands in the media folder"] = function()
        MediaInfo.reset()
        local path = TMP .. "/mediainfo-late.png"
        os.remove(path)
        -- First render happens before the user copies collection.media over USB;
        -- that miss must not be remembered, or the picture stays unscaled until
        -- KOReader restarts.
        assert(MediaInfo.measure(path) == nil)
        write("late.png", png(320, 200))
        assert(MediaInfo.measure(path) == 320)
        MediaInfo.reset()
    end,
}
