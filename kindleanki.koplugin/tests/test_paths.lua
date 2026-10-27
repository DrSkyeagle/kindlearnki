local Paths = require("core.paths")

return {
    ["paths live under a plugin-owned namespace"] = function()
        local p = Paths.new("/mnt/us/koreader", "/mnt/us/koreader/settings")
        assert(p.root == "/mnt/us/koreader/kindleanki", p.root)
        assert(p.collection == "/mnt/us/koreader/kindleanki/collection.anki2", p.collection)
        assert(p.media_dir == "/mnt/us/koreader/kindleanki/media", p.media_dir)
        assert(p.settings_file == "/mnt/us/koreader/settings/kindleanki.lua", p.settings_file)
        assert(p.ca_bundle == "/mnt/us/koreader/data/ca-bundle.crt", p.ca_bundle)
    end,

    ["trailing slashes are normalised"] = function()
        local p = Paths.new("/mnt/us/koreader/", "/mnt/us/koreader/settings//")
        assert(not p.root:find("//", 1, true), p.root)
        assert(not p.settings_file:find("//", 1, true), p.settings_file)
    end,

    ["the old plugin namespace is not touched"] = function()
        local p = Paths.new("/mnt/us/koreader", "/mnt/us/koreader/settings")
        assert(not p.root:find("ankiweb", 1, true), p.root)
    end,

    ["empty directories are rejected"] = function()
        assert(not pcall(Paths.new, "", "/mnt/us/koreader/settings"))
        assert(not pcall(Paths.new, "/mnt/us/koreader", ""))
    end,
}
