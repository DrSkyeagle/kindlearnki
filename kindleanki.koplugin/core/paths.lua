-- Every filesystem path the plugin owns, in one place.
--
-- Nothing else may build a path out of DataStorage directly: the device path
-- (`/mnt/us/koreader`), the desktop emulator path (`~/.config/koreader`) and the
-- test substitutes all differ, and hard-coded fragments are how the old plugin
-- ended up unable to find its own database in one environment.

local Paths = {}

local function trim_trailing_slashes(path)
    return (tostring(path):gsub("/+$", ""))
end

--- Build the path table from the two KOReader directories.
-- @string data_dir      DataStorage:getDataDir()
-- @string settings_dir  DataStorage:getSettingsDir()
-- @treturn table
function Paths.new(data_dir, settings_dir)
    assert(type(data_dir) == "string" and data_dir ~= "", "data_dir is required")
    assert(type(settings_dir) == "string" and settings_dir ~= "", "settings_dir is required")

    local data = trim_trailing_slashes(data_dir)
    local settings = trim_trailing_slashes(settings_dir)
    local root = data .. "/kindleanki"

    return {
        -- KOReader's own directories, kept so callers can reach shared files
        -- such as the CA bundle without guessing where it lives.
        koreader_data_dir = data,
        koreader_settings_dir = settings,

        -- Plugin-owned namespace.  Deliberately not "ankiweb": the old plugin
        -- keeps its data where it is so the two can be installed side by side.
        root = root,
        collection = root .. "/collection.anki2",
        media_dir = root .. "/media",
        backup_dir = root .. "/backup",

        settings_file = settings .. "/kindleanki.lua",
        ca_bundle = data .. "/data/ca-bundle.crt",
    }
end

--- Resolve the paths from the running KOReader instance.
function Paths.for_koreader()
    local DataStorage = require("datastorage")
    return Paths.new(DataStorage:getDataDir(), DataStorage:getSettingsDir())
end

return Paths
