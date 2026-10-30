local Paths = require("core.paths")
local Helpers = require("helpers")

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

    ["ensure creates the plugin directories on a fresh install"] = function()
        local base = Helpers.root .. "/../out/tmp/paths-ensure-" .. tostring(os.time())
            .. "-" .. tostring(math.random(1000, 9999))
        local p = Paths.new(base, base .. "/settings")
        local ok, err = Paths.ensure(p)
        assert(ok, tostring(err))

        -- Writing a file inside each directory is the portable proof that the
        -- directory really exists (Lua has no readdir).
        for _, dir in ipairs({ p.root, p.media_dir, p.backup_dir }) do
            local handle, open_error = io.open(dir .. "/probe.txt", "wb")
            assert(handle, "cannot write in " .. dir .. ": " .. tostring(open_error))
            handle:write("x")
            handle:close()
            os.remove(dir .. "/probe.txt")
        end
    end,

    ["ensure is idempotent"] = function()
        local base = Helpers.root .. "/../out/tmp/paths-again-" .. tostring(os.time())
            .. "-" .. tostring(math.random(1000, 9999))
        local p = Paths.new(base, base .. "/settings")
        assert(Paths.ensure(p))
        local ok, err = Paths.ensure(p)
        assert(ok, "second call failed: " .. tostring(err))
    end,

    ["mkdir_p creates nested parents"] = function()
        local nested = Helpers.root .. "/../out/tmp/paths-nested-" .. tostring(os.time())
            .. "-" .. tostring(math.random(1000, 9999)) .. "/a/b/c"
        assert(Paths.mkdir_p(nested))
        local handle = assert(io.open(nested .. "/probe.txt", "wb"))
        handle:close()
        os.remove(nested .. "/probe.txt")
    end,
}
