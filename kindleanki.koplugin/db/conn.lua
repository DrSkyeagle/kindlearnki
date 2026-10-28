-- Thin, allocation-aware wrapper around lua-ljsqlite3.
--
-- Why not call ljsqlite3 directly everywhere:
--   * BLOB columns come back as {ptr, size} tables whose memory is only valid
--     until the next step; they must be copied before the iterator advances.
--   * Statements are reused per connection, which is the difference between
--     "484 point updates" and "484 prepares" (measured in the old project).
--   * Every failure path has to close or reset what it opened, or the file
--     stays locked for the rest of the process.

local Conn = {}
local ConnMT = { __index = Conn }

--[[ lua-ljsqlite3 looks its library up through `ffi.loadlib`, which KOReader
installs (it resolves `libs/libsqlite3.so.0`).  A bare LuaJIT — the L1 test
runner — has no such helper, so fall back to `ffi.load`, which finds the
`sqlite3.dll` shipped next to tools/lj/luajit.exe. ]]
local function ensure_loadlib()
    local ffi = require("ffi")
    if type(ffi.loadlib) == "function" then
        return
    end
    pcall(require, "ffi/loadlib")
    if type(ffi.loadlib) == "function" then
        return
    end
    ffi.loadlib = function(name, version)
        -- Windows DLLs are `sqlite3.dll`, not `sqlite3.0.dll`; the version
        -- suffix only exists on the ELF side (libsqlite3.so.0).
        if package.config:sub(1, 1) == "\\" then
            return ffi.load(name)
        end
        return ffi.load(name .. (version and ("." .. version) or ""))
    end
end

local function copy_row(row)
    for i = 1, #row do
        local value = row[i]
        if type(value) == "table" and value[1] ~= nil and value[2] ~= nil then
            -- BLOB: valid only until the next step(), so copy now.
            local ffi = require("ffi")
            row[i] = ffi.string(value[1], value[2])
        elseif type(value) == "cdata" then
            -- ljsqlite3 returns INTEGER columns as int64 cdata.  Every id and
            -- timestamp this plugin handles is below 2^53, and mixing cdata
            -- keys with number keys silently breaks table lookups (deck ids
            -- compared as different types), so normalise at the boundary.
            local number = tonumber(value)
            if number then
                row[i] = number
            end
        end
    end
    return row
end

--- @string path        collection file
--- @bool read_only     open with SQLITE_OPEN_READONLY
function Conn.open(path, read_only)
    ensure_loadlib()
    local sqlite3 = require("lua-ljsqlite3/init")
    local db = sqlite3.open(path, read_only and "ro" or "rw")
    db:set_busy_timeout(5000)
    return setmetatable({
        db = db,
        path = path,
        read_only = read_only and true or false,
        cache = {},
        closed = false,
    }, ConnMT)
end

function Conn:check_open()
    if self.closed then
        error("connection is closed: " .. tostring(self.path), 2)
    end
end

--- Reusable prepared statement. Callers must not nest iteration over the same
--- SQL text; the scheduler and sync paths use distinct statements.
function Conn:statement(sql)
    self:check_open()
    local stmt = self.cache[sql]
    if not stmt then
        stmt = self.db:prepare(sql)
        self.cache[sql] = stmt
    end
    stmt:reset()
    stmt:clearbind()
    return stmt
end

function Conn:exec(sql)
    self:check_open()
    return self.db:exec(sql)
end

--- All rows as tables of positional columns.
function Conn:all(sql, ...)
    local stmt = self:statement(sql)
    if select("#", ...) > 0 then
        stmt:bind(...)
    end
    local rows = {}
    for row in stmt:rows() do
        rows[#rows + 1] = copy_row(row)
    end
    return rows
end

function Conn:first(sql, ...)
    local stmt = self:statement(sql)
    if select("#", ...) > 0 then
        stmt:bind(...)
    end
    local row = stmt:step()
    if not row then
        return nil
    end
    return copy_row(row)
end

--- Execute a statement that returns no rows (insert/update/delete).
function Conn:run(sql, ...)
    local stmt = self:statement(sql)
    if select("#", ...) > 0 then
        stmt:bind(...)
    end
    local row = stmt:step()
    -- A row here means the SQL was a SELECT by mistake; consume nothing more.
    return row ~= nil
end

--- Run `fn` inside BEGIN/COMMIT; ROLLBACK on any error and re-raise.
function Conn:transaction(fn)
    self:exec("begin immediate")
    local ok, result = pcall(fn)
    if ok then
        self:exec("commit")
        return result
    end
    pcall(self.exec, self, "rollback")
    error(result, 0)
end

function Conn:close()
    if self.closed then
        return
    end
    self.closed = true
    for sql, stmt in pairs(self.cache) do
        pcall(stmt.close, stmt)
        self.cache[sql] = nil
    end
    pcall(self.db.close, self.db)
end

return Conn
