-- What the host must provide before any of this plugin can work.
--
-- The old plugin failed silently in several environments because a missing
-- module only surfaced from inside a UI callback, where KOReader catches the
-- error and writes one line to crash.log.  The rule here: probe everything once,
-- at load time, and log a single line that names every missing piece.
--
-- Every probe is injectable (`overrides`, `require_fn`) so unit tests can run
-- this file on a bare LuaJIT with no KOReader tree at all.

local Capabilities = {}

-- Order matters only for the human-readable summary.
local ORDER = { "html", "sqlite", "zstd", "ca" }

local function check_html(req)
    local ok, HtmlBoxWidget = pcall(req, "ui/widget/htmlboxwidget")
    return ok and type(HtmlBoxWidget) == "table"
        and type(HtmlBoxWidget.setContent) == "function"
end

local function check_sqlite(req)
    local ok, mod = pcall(req, "lua-ljsqlite3/init")
    return ok and mod ~= nil
end

local function check_zstd()
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi or type(ffi) ~= "table" then
        return false
    end
    -- KOReader monkey-patches ffi.loadlib so that "libzstd.so.1" is found
    -- through its own libs/ directory; on a stock LuaJIT this stays absent and
    -- the probe correctly reports "no".
    pcall(require, "ffi/loadlib")
    if type(ffi.loadlib) ~= "function" then
        return false
    end
    local ok_lib, lib = pcall(ffi.loadlib, "zstd", "1")
    if not ok_lib or lib == nil then
        return false
    end
    -- Symbol-level verification (ZSTD_decompressStream and friends) belongs to
    -- sync/zstd.lua, which owns those cdefs; declaring them here just to read
    -- the symbols would collide with that module's declarations.  A loadable
    -- libzstd.so.1 is the right granularity for a host probe.
    return true
end

local function check_ca(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    local head = file:read(32)
    file:close()
    return head ~= nil and #head > 0
end

local function read_version(req)
    local ok, Version = pcall(req, "version")
    if not ok or type(Version) ~= "table" or type(Version.getCurrentRevision) ~= "function" then
        return nil
    end
    local ok_rev, revision = pcall(Version.getCurrentRevision, Version)
    if ok_rev and revision ~= nil then
        return tostring(revision)
    end
    return nil
end

local function read_model(req)
    local ok, Device = pcall(req, "device")
    if ok and type(Device) == "table" and Device.model ~= nil then
        return tostring(Device.model)
    end
    return nil
end

--- Probe the host.
--
-- @tparam table opts
--   require_fn   replacement for `require` (tests)
--   overrides    table of probe name -> boolean, replaces the real check
--   ca_path      path to KOReader's CA bundle
--   ko_version   string, replaces the version read
--   model        string, replaces the device model read
-- @treturn table { values = {...}, missing = {...}, ok = boolean, summary = string }
function Capabilities.probe(opts)
    opts = opts or {}
    local req = opts.require_fn or require
    local overrides = opts.overrides or {}
    local values = {}
    local missing = {}

    local function run(key, fn)
        local value
        if overrides[key] ~= nil then
            value = overrides[key] and true or false
        else
            local ok, result = pcall(fn)
            value = (ok and result) and true or false
        end
        values[key] = value
        if not value then
            missing[#missing + 1] = key
        end
    end

    run("html", function()
        return check_html(req)
    end)
    run("sqlite", function()
        return check_sqlite(req)
    end)
    run("zstd", check_zstd)
    run("ca", function()
        return check_ca(opts.ca_path)
    end)

    local ko_version = opts.ko_version or read_version(req)
    local model = opts.model or read_model(req)

    local parts = {}
    if ko_version then
        parts[#parts + 1] = "koreader=" .. ko_version
    end
    if model then
        parts[#parts + 1] = "model=" .. model
    end
    parts[#parts + 1] = "html=" .. (values.html and "ok" or "no")
    parts[#parts + 1] = "sqlite=" .. (values.sqlite and "ok" or "no")
    parts[#parts + 1] = "zstd=" .. (values.zstd and "ok" or "no")
    parts[#parts + 1] = "ca=" .. (values.ca and "yes" or "no")

    return {
        values = values,
        missing = missing,
        -- Without a database or an HTML renderer there is no point pretending
        -- the study screen can work; sync-only would still need sqlite.
        ok = values.sqlite and values.html,
        summary = table.concat(parts, " "),
    }
end

Capabilities.ORDER = ORDER

return Capabilities
