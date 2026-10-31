-- Crash breadcrumbs.
--
-- A native crash (segfault inside LuaSec, an OOM kill, a Kindle watchdog) takes
-- KOReader down without giving Lua a chance to flush its log buffer, so
-- crash.log can end a few lines before the interesting point.  This module
-- writes a single line to a small file and closes it on every stage: whatever
-- the process does afterwards, the last completed stage survives on disk.
--
-- `main.lua` marks the start of each risky step and reports the previous run's
-- last mark in the log on the next start.

local Trace = {}

local path

--- Point the module at the plugin data dir (`paths.root`).
function Trace.init(root)
    path = root and (root .. "/last-stage.txt") or nil
end

--- Record a stage. Never raises: a diagnostic that can fail is worse than none.
function Trace.mark(stage)
    if not path then
        return
    end
    pcall(function()
        local file = io.open(path, "w")
        if file then
            file:write(string.format("%s %s\n", os.date("%Y-%m-%d %H:%M:%S"),
                tostring(stage)))
            file:close() -- close flushes; no buffered data is left to lose
        end
    end)
end

--- Last recorded stage from the previous run, or nil.
function Trace.last()
    if not path then
        return nil
    end
    local file = io.open(path, "r")
    if not file then
        return nil
    end
    local line = file:read("*l")
    file:close()
    return line
end

--- Forget the breadcrumb (called after a successful start-up so a stale mark
--- does not look like a crash next time).
function Trace.clear()
    if not path then
        return
    end
    pcall(os.remove, path)
end

Trace.path = function()
    return path
end

return Trace
