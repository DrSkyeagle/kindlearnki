-- One logging surface for the whole plugin.
--
-- KOReader's `logger` already writes to crash.log, but it is a hard dependency
-- that unit tests cannot load.  So this module owns a sink: the plugin installs
-- one wrapped around `logger`, tests install a capture function, and everything
-- else just calls `Log.info(...)`.
--
-- Never log the host key or a password.  `Log.secret()` exists so call sites
-- have an obvious way to say "this must be redacted".

local Log = {}

Log.PREFIX = "kindlearnki"

local sink = nil

--- Install the destination for log lines.  `fn(level, message)`; any error in
--- the sink falls back to stderr rather than taking the caller down.
function Log.set_sink(fn)
    sink = fn
end

function Log.reset()
    sink = nil
end

local function emit(level, ...)
    local n = select("#", ...)
    local parts = {}
    for i = 1, n do
        parts[i] = tostring((select(i, ...)))
    end
    local message = table.concat(parts, " ")
    if sink then
        local ok = pcall(sink, level, message)
        if ok then
            return
        end
    end
    io.stderr:write(string.format("[%s] %s: %s\n", level, Log.PREFIX, message))
end

function Log.dbg(...)
    emit("dbg", ...)
end

function Log.info(...)
    emit("info", ...)
end

function Log.warn(...)
    emit("warn", ...)
end

function Log.err(...)
    emit("err", ...)
end

--- Render a value so it can be logged without leaking a credential.
function Log.secret(value)
    if value == nil or value == "" then
        return "<empty>"
    end
    return "<redacted:" .. tostring(#tostring(value)) .. ">"
end

return Log
