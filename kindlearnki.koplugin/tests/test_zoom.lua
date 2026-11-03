--[[--
The two zoom settings: font scaling (pure arithmetic) and the image rewrite.

The image side is pinned to the numbers measured on the firmware build: MuPDF
draws one image pixel as 0.75 CSS px, and a CSS px is a device pixel, so a
600 px wide picture is 450 px at 100% and 675 px at 150%.
]]

local Helpers = require("helpers")
local Tokens = require("ui.tokens")

local TMP = Helpers.root .. "/../out/tmp"
local MEDIA = TMP

local function be32(value)
    return string.char(
        math.floor(value / 16777216) % 256,
        math.floor(value / 65536) % 256,
        math.floor(value / 256) % 256,
        value % 256)
end

--- A 600x400 PNG header is all `MediaInfo` needs.
local function write_png(name, width, height)
    local path = MEDIA .. "/" .. name
    local file = assert(io.open(path, "wb"), "cannot write " .. path)
    file:write("\137PNG\r\n\26\n" .. be32(13) .. "IHDR"
        .. be32(width) .. be32(height) .. "\8\2\0\0\0" .. string.rep("\0", 40))
    file:close()
    return path
end

return {
    ["the font zoom multiplies the base size and rounds"] = function()
        assert(Tokens.scaled_font_px(38, 100) == 38)
        assert(Tokens.scaled_font_px(38, 150) == 57)
        assert(Tokens.scaled_font_px(38, 50) == 19)
        assert(Tokens.scaled_font_px(38, 200) == 76)
    end,

    ["the font zoom never produces an unreadable or oversized line"] = function()
        assert(Tokens.scaled_font_px(20, 50) == 12, tostring(Tokens.scaled_font_px(20, 50)))
        assert(Tokens.scaled_font_px(60, 200) == 96, tostring(Tokens.scaled_font_px(60, 200)))
    end,

    ["a missing percentage means the default size"] = function()
        assert(Tokens.scaled_font_px(38, nil) == 38)
        assert(Tokens.scaled_font_px(38, "150") == 57)
    end,

    ["100% leaves the card byte for byte alone"] = function()
        local html = '<div class="card">x<img src="a.png"></div>'
        local out, css = Tokens.scale_images(html, MEDIA, 100)
        assert(out == html, out)
        assert(css == "", css)
    end,

    ["an image is wrapped and given the measured width"] = function()
        write_png("zoom-a.png", 600, 400)
        local html = '<div class="card"><img src="zoom-a.png"></div>'
        local out, css = Tokens.scale_images(html, MEDIA, 150)
        assert(out:find('<div class="ka-zoom-1"><img src="zoom-a.png"></div>', 1, true),
            out)
        -- 600 natural * 0.75 (MuPDF's page scale) * 150% = 675
        assert(css:find(".ka-zoom-1 img { width: 675px; }", 1, true), css)
    end,

    ["shrinking uses the same scale"] = function()
        write_png("zoom-b.png", 1200, 800)
        local _, css = Tokens.scale_images('<img src="zoom-b.png">', MEDIA, 50)
        -- 1200 * 0.75 * 50% = 450
        assert(css:find("width: 450px;", 1, true), css)
    end,

    ["remote and unknown images are left as they are"] = function()
        local html = '<img src="https://example.com/a.png"><img src="missing.png">'
        local out, css = Tokens.scale_images(html, MEDIA, 150)
        assert(out == html, out)
        assert(css == "", css)
    end,

    ["a percent-encoded name is decoded before measuring"] = function()
        write_png("zoom c.png", 400, 300)
        local html = '<img src="zoom%20c.png">'
        local out, css = Tokens.scale_images(html, MEDIA, 200)
        -- 400 * 0.75 * 200% = 600
        assert(css:find("width: 600px;", 1, true), css)
        -- the tag itself keeps the name the card wrote
        assert(out:find("zoom%20c.png", 1, true), out)
    end,

    ["a '>' inside an attribute does not end the tag early"] = function()
        write_png("zoom-d.png", 200, 100)
        local html = '<img alt="a > b" src="zoom-d.png">'
        local out, css = Tokens.scale_images(html, MEDIA, 200)
        -- 200 * 0.75 * 200% = 300
        assert(css:find("width: 300px;", 1, true), css)
        assert(out:find('<img alt="a > b" src="zoom-d.png">', 1, true), out)
        assert(out:find('<div class="ka-zoom-1">', 1, true), out)
    end,

    ["no media directory means no rewrite"] = function()
        local html = '<img src="a.png">'
        local out, css = Tokens.scale_images(html, nil, 150)
        assert(out == html and css == "")
    end,

    ["several images get their own classes"] = function()
        write_png("zoom-e1.png", 100, 100)
        write_png("zoom-e2.png", 300, 300)
        local html = '<img src="zoom-e1.png"><p>x</p><img src="zoom-e2.png">'
        local out, css = Tokens.scale_images(html, MEDIA, 100)
        assert(css == "", css)
        local wrapped, rules = Tokens.scale_images(html, MEDIA, 200)
        assert(wrapped:find("ka-zoom-1", 1, true) and wrapped:find("ka-zoom-2", 1, true),
            wrapped)
        -- 100 * 0.75 * 2 = 150, 300 * 0.75 * 2 = 450
        assert(rules:find("width: 150px;", 1, true), rules)
        assert(rules:find("width: 450px;", 1, true), rules)
    end,
}
