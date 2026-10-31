-- Crash breadcrumbs must survive a process death, so the file is written and
-- closed on every mark; these tests check the file really is on disk and that a
-- stale mark can be cleared.

local Trace = require("core.trace")
local Helpers = require("helpers")

local DIR = Helpers.root .. "/../out/tmp/trace-test"

local function ensure_dir()
    if package.config:sub(1, 1) == "\\" then
        os.execute('mkdir "' .. (DIR:gsub("/", "\\")) .. '" >nul 2>nul')
    else
        os.execute('mkdir -p "' .. DIR .. '" 2>/dev/null')
    end
end

local function read_line()
    local file = io.open(DIR .. "/last-stage.txt", "r")
    if not file then
        return nil
    end
    local line = file:read("*l")
    file:close()
    return line
end

return {
    ["mark writes a readable line to disk"] = function()
        ensure_dir()
        Trace.init(DIR)
        Trace.mark("login.request.start")
        local line = read_line()
        assert(line and line:find("login.request.start", 1, true),
            "breadcrumb not persisted: " .. tostring(line))
    end,

    ["last returns the most recent stage"] = function()
        ensure_dir()
        Trace.init(DIR)
        Trace.mark("sync.pull")
        Trace.mark("sync.push")
        local last = Trace.last()
        assert(last and last:find("sync.push", 1, true),
            "last stage is stale: " .. tostring(last))
    end,

    ["clear removes the breadcrumb"] = function()
        ensure_dir()
        Trace.init(DIR)
        Trace.mark("done")
        Trace.clear()
        assert(Trace.last() == nil, "breadcrumb survived clear()")
    end,

    ["marking without init is a no-op"] = function()
        ensure_dir()
        Trace.init(nil)
        Trace.mark("ignored")
        assert(Trace.last() == nil)
    end,
}
