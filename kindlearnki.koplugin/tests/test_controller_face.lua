--[[--
`study/controller.lua`'s face builder: the hand-off between the renderer and
the study screen.

The bug this pins: the study screen asks for a resource directory and MuPDF
needs it to resolve `<img src="paste-1234.jpg">`, but the face table never
carried one -- so every image on every card became the literal `[image]`
placeholder even when the file was on the device.  The face builder is public
exactly so this can be checked without opening a session or a screen.
]]

local Controller = require("study.controller")

local NOTETYPE = {
    kind = 0,
    css = ".card { color: #000; }",
    fields = { { name = "Front" }, { name = "Back" } },
    templates = { {
        ord = 0,
        name = "Card 1",
        qfmt = "{{Front}}",
        afmt = "{{FrontSide}}<hr>{{Back}}",
    } },
}

local function item_with(front)
    return {
        notetype = NOTETYPE,
        note = { fields = { front, "背面" }, tags = "" },
        card = { ord = 0 },
        context = { deck_name = "测试", card_name = "Card 1" },
    }
end

return {
    ["the face carries the media directory"] = function()
        local face = Controller.face(item_with("前"), { media_dir = "/mnt/us/media" })
        assert(face.resource_dir == "/mnt/us/media",
            "the MuPDF widget would be built without a resource directory")
        assert(type(face.html) == "string" and face.html:find("前", 1, true))
        assert(face.answer_html, "the answer face is gone")
    end,

    ["an image the card references is kept in the html"] = function()
        -- The media files themselves are the user's business: a card may point
        -- at pictures that were deliberately never copied over, and that must
        -- stay a rendering detail, not a warning on the study screen.
        local face = Controller.face(item_with('<img src="cat.png">'), {
            media_dir = "/mnt/us/media",
        })
        assert(face.html:find('<img src="cat.png"', 1, true), face.html)
        assert(face.missing_media == nil, "the face must not report missing media")
    end,

    ["no media directory still renders the card"] = function()
        local face = Controller.face(item_with('前<img src="cat.png">'))
        assert(face.resource_dir == nil)
        assert(face.html:find("前", 1, true), "the card text was lost")
    end,

    ["a nil item yields an empty face"] = function()
        local face = Controller.face(nil, { media_dir = "/mnt/us/media" })
        assert(face.html == "" and face.resource_dir == "/mnt/us/media")
    end,
}
