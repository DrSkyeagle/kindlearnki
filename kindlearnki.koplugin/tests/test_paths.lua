local Paths = require("core.paths")
local Helpers = require("helpers")

return {
    ["paths live under a plugin-owned namespace"] = function()
        local p = Paths.new("/mnt/us/koreader", "/mnt/us/koreader/settings")
        assert(p.root == "/mnt/us/koreader/kindlearnki", p.root)
        assert(p.collection == "/mnt/us/koreader/kindlearnki/collection.anki2", p.collection)
        assert(p.media_dir == "/mnt/us/koreader/kindlearnki/media", p.media_dir)
        assert(p.settings_file == "/mnt/us/koreader/settings/kindlearnki.lua", p.settings_file)
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

    ["the pre-0.3.0 install is copied across once"] = function()
        local base = Helpers.root .. "/../out/tmp/paths-migrate-" .. tostring(os.time())
            .. "-" .. tostring(math.random(1000, 9999))
        local legacy = base .. "/kindleanki"
        local legacy_settings = base .. "/settings-old"
        assert(Paths.mkdir_p(legacy))
        assert(Paths.mkdir_p(legacy_settings))
        local handle = assert(io.open(legacy .. "/collection.anki2", "wb"))
        handle:write("COLLECTION")
        handle:close()
        handle = assert(io.open(legacy .. "/collection.anki2-wal", "wb"))
        handle:write("WAL")
        handle:close()
        handle = assert(io.open(legacy_settings .. "/kindleanki.lua", "wb"))
        handle:write('return { hkey = "legacy" }\n')
        handle:close()

        local p = Paths.new(base, legacy_settings)
        local moved = Paths.migrate_legacy(p)
        assert(moved.collection == true, "collection was not migrated")
        assert(moved.settings == true, "settings were not migrated")

        handle = assert(io.open(p.collection, "rb"))
        assert(handle:read("*a") == "COLLECTION", "collection content differs")
        handle:close()
        handle = assert(io.open(p.collection .. "-wal", "rb"))
        assert(handle:read("*a") == "WAL", "the WAL must travel with the collection")
        handle:close()
        handle = assert(io.open(p.settings_file, "rb"))
        assert(handle:read("*a"):find("legacy", 1, true), "settings content differs")
        handle:close()

        -- Second start: nothing to do, and nothing overwritten.
        local again = Paths.migrate_legacy(p)
        assert(again.collection ~= true, "migration must not run twice")
        assert(again.settings ~= true, "settings migration must not run twice")
    end,

    ["mkdir_p creates nested parents"] = function()
        local nested = Helpers.root .. "/../out/tmp/paths-nested-" .. tostring(os.time())
            .. "-" .. tostring(math.random(1000, 9999)) .. "/a/b/c"
        assert(Paths.mkdir_p(nested))
        local handle = assert(io.open(nested .. "/probe.txt", "wb"))
        handle:close()
        os.remove(nested .. "/probe.txt")
    end,

    ["media defaults to the plugin's own folder"] = function()
        local p = Paths.new("/mnt/us/koreader", "/mnt/us/koreader/settings")
        assert(Paths.media_source(p) == p.media_dir)
        assert(Paths.media_source(p, "") == p.media_dir)
        assert(Paths.media_source(p, "   ") == p.media_dir)
    end,

    ["the media_dir setting wins over the default"] = function()
        local p = Paths.new("/mnt/us/koreader", "/mnt/us/koreader/settings")
        assert(Paths.media_source(p, "/mnt/us/documents/collection.media")
            == "/mnt/us/documents/collection.media")
        -- Trailing slashes are the difference between `<dir>//a.png` and a
        -- path MuPDF can resolve, so they are normalised here, not later.
        assert(Paths.media_source(p, "/mnt/us/documents/collection.media//")
            == "/mnt/us/documents/collection.media")
    end,

    ["an unusable media_dir falls back to the default"] = function()
        local p = Paths.new("/mnt/us/koreader", "/mnt/us/koreader/settings")
        assert(Paths.media_source(p, "/") == p.media_dir)
        assert(Paths.media_source(p, "//") == p.media_dir)
        assert(not pcall(Paths.media_source, nil))
    end,

    ["remove_library takes the collection, its sidecars and the backup"] = function()
        local base = Helpers.root .. "/../out/tmp/paths-remove-" .. tostring(os.time())
            .. "-" .. tostring(math.random(1000, 9999))
        local p = Paths.new(base, base .. "/settings")
        assert(Paths.ensure(p))
        for _, path in ipairs(Paths.library_files(p)) do
            local handle = assert(io.open(path, "wb"))
            handle:write("x")
            handle:close()
        end

        local result = Paths.remove_library(p)
        assert(#result.removed == 4, "expected 4 files, removed " .. #result.removed)
        assert(#result.failed == 0, "unexpected failure: " .. tostring(result.failed[1]))
        for _, path in ipairs(Paths.library_files(p)) do
            assert(io.open(path, "rb") == nil, "still on disk: " .. path)
        end
    end,

    ["remove_library keeps the login"] = function()
        -- The whole point of the menu entry: a clean library without losing the
        -- hkey, so the next sync is a plain full download.
        local base = Helpers.root .. "/../out/tmp/paths-keepkey-" .. tostring(os.time())
            .. "-" .. tostring(math.random(1000, 9999))
        local p = Paths.new(base, base .. "/settings")
        assert(Paths.ensure(p))
        assert(Paths.mkdir_p(base .. "/settings"))
        local handle = assert(io.open(p.collection, "wb"))
        handle:write("x")
        handle:close()
        handle = assert(io.open(p.settings_file, "wb"))
        handle:write('return { hkey = "keep-me" }')
        handle:close()

        assert(#Paths.remove_library(p).removed == 1)
        local settings = assert(io.open(p.settings_file, "rb"), "settings were deleted")
        assert(settings:read("*a"):find("keep-me", 1, true), "the hkey was lost")
        settings:close()
    end,

    ["remove_library on a fresh install is a no-op"] = function()
        local base = Helpers.root .. "/../out/tmp/paths-empty-" .. tostring(os.time())
            .. "-" .. tostring(math.random(1000, 9999))
        local p = Paths.new(base, base .. "/settings")
        local result = Paths.remove_library(p)
        assert(#result.removed == 0, "removed something that never existed")
        assert(#result.failed == 0, "a missing file must not be an error")
    end,
}
