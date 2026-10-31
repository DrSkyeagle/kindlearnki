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
    local root = data .. "/kindlearnki"

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

        settings_file = settings .. "/kindlearnki.lua",
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
-- The first-run path needs this: on a fresh device `<data>/kindlearnki/` does not
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

--==========================================================================
-- Migration from the pre-0.3.0 name
--==========================================================================
-- The plugin was called kindleanki until 0.3.0, so an existing install keeps
-- its collection, WAL and AnkiWeb key under `koreader/kindleanki/` and
-- `koreader/settings/kindleanki.lua`.  Copying them on the first start after
-- the rename is what stops an upgrade from looking like "all my progress and
-- my login vanished".  The old files are left alone: they cost nothing and are
-- the only backup if the copy is interrupted.

local LEGACY_ROOT = "kindleanki"
local LEGACY_SETTINGS = "kindleanki.lua"

local function file_exists(path)
    local handle = io.open(path, "rb")
    if handle then
        handle:close()
        return true
    end
    return false
end

local function copy_file(from, to)
    local source = io.open(from, "rb")
    if not source then
        return false
    end
    local data = source:read("*a")
    source:close()
    local target = io.open(to, "wb")
    if not target then
        return false
    end
    target:write(data)
    target:close()
    return true
end

--- Copy the pre-0.3.0 collection and settings when the new paths are empty.
-- @treturn table `{ collection = true?, settings = true?, legacy_root = path }`
function Paths.migrate_legacy(paths)
    local legacy_root = paths.koreader_data_dir .. "/" .. LEGACY_ROOT
    local legacy_settings = paths.koreader_settings_dir .. "/" .. LEGACY_SETTINGS
    local moved = { legacy_root = legacy_root }

    Paths.mkdir_p(paths.root)

    local legacy_collection = legacy_root .. "/collection.anki2"
    if not file_exists(paths.collection) and file_exists(legacy_collection) then
        -- `-wal`/`-shm` carry the last transactions; copying the main file
        -- alone would drop the reviews that are still only in the WAL.
        for _, suffix in ipairs({ "", "-wal", "-shm" }) do
            copy_file(legacy_collection .. suffix, paths.collection .. suffix)
        end
        moved.collection = true
    end

    if not file_exists(paths.settings_file) and file_exists(legacy_settings) then
        moved.settings = copy_file(legacy_settings, paths.settings_file) or nil
    end

    return moved
end

return Paths
