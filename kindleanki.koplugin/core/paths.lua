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

local function split_path(path)
    local parts = {}
    for part in tostring(path):gmatch("[^/]+") do
        parts[#parts + 1] = part
    end
    return parts
end

local function shell_mkdir(dir)
    if package.config:sub(1, 1) == "\\" then
        os.execute('mkdir "' .. (dir:gsub("/", "\\")) .. '" >nul 2>nul')
    else
        os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
    end
end

--- Create a directory and every missing parent.
--
-- The first-run path needs this: on a fresh device `<data>/kindleanki/` does not
-- exist, and SQLite reports `cantopen` when the parent directory is missing
-- rather than creating it.  KOReader ships lfs; the shell fallback exists for
-- the bare-LuaJIT test runner.
function Paths.mkdir_p(path)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and lfs.mkdir then
        local absolute = path:sub(1, 1) == "/"
        local prefix = ""
        for _, part in ipairs(split_path(path)) do
            if prefix == "" then
                prefix = absolute and ("/" .. part) or part
            else
                prefix = prefix .. "/" .. part
            end
            if lfs.attributes(prefix, "mode") ~= "directory" then
                local made, err = lfs.mkdir(prefix)
                if not made and lfs.attributes(prefix, "mode") ~= "directory" then
                    return nil, "无法创建目录 " .. prefix .. "：" .. tostring(err)
                end
            end
        end
        return true
    end
    shell_mkdir(path)
    return true
end

--- Create the plugin's own directories; safe to call on every start.
function Paths.ensure(paths)
    for _, dir in ipairs({ paths.root, paths.media_dir, paths.backup_dir }) do
        local ok, err = Paths.mkdir_p(dir)
        if not ok then
            return nil, err
        end
    end
    return true
end

return Paths
