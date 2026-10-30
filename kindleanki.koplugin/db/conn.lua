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

--==========================================================================
-- BLOB binding
--==========================================================================
-- lua-ljsqlite3 has no `stmt:bind_blob`.  Its only BLOB channel is the tagged
-- table built by `SQ3.blob(ptr, size)`, and that one requires `ptr` to come
-- from libc malloc: after binding with SQLITE_TRANSIENT the library calls
-- `free(v[1])` on it (see `sql_set_code` in common/lua-ljsqlite3/init.lua).
-- KOReader's coverbrowser plugin does exactly that with a zstd-owned buffer.
--
-- We cannot use that path: the L1 test runner is a bare LuaJIT where `ffi.C`
-- exposes no malloc/free at all (tests/run.lua even shims the library's
-- `free = C.free` into a no-op so the module can load on Windows).  Allocating
-- a buffer per counter update would also be wasteful for a ~40 byte protobuf.
--
-- So we call sqlite3_bind_blob directly (the cdef is registered by
-- lua-ljsqlite3 when it is required; the library handle below is the same
-- `ffi.loadlib("sqlite3", "0")` the module itself resolves):
--
--   * destructor argument is nil == SQLITE_STATIC: SQLite neither copies nor
--     frees the buffer, it only reads it while stepping.  A Lua string is
--     immutable and never moved by the GC, and the caller keeps a reference
--     across the step, so the pointer stays valid.
--   * Conn:statement() resets and clears bindings before reusing a statement;
--     sqlite3_reset/finalize do not dereference STATIC pointers, so a later
--     reuse can never read a stale one.

local BLOB_MARKER = {} -- metatable identity for Conn.blob() wrappers

--- Mark `bytes` so Conn:run/first/all bind it as a BLOB (not TEXT).
-- Storage class matters: the schema declares decks.common, notetypes.config,
-- deck_config.config, ... as BLOB, and Anki's rslib reads them as Vec<u8>.  A
-- plain Lua string is bound as TEXT and makes the whole collection unreadable
-- by Anki ("InvalidType").
-- @tparam string bytes raw bytes
-- @treturn table marker understood by the bind helpers below
function Conn.blob(bytes)
    return setmetatable({ bytes = tostring(bytes or "") }, BLOB_MARKER)
end

local function is_blob(value)
    return type(value) == "table" and getmetatable(value) == BLOB_MARKER
end

local sqlite_lib

local function sqlite_namespace()
    if not sqlite_lib then
        sqlite_lib = require("ffi").loadlib("sqlite3", "0")
    end
    return sqlite_lib
end

local function bind_blob(stmt, index, bytes)
    local ffi = require("ffi")
    local code = sqlite_namespace().sqlite3_bind_blob(stmt._ptr, index,
        ffi.cast("const void *", bytes), #bytes, nil)
    if code ~= 0 then
        error(string.format("sqlite3_bind_blob(%d) failed (%d)", index, code), 0)
    end
end

--- Bind a positional argument list, routing Conn.blob() markers to bind_blob.
-- The no-marker fast path stays a single `stmt:bind(...)` call.
local function bind_arguments(stmt, ...)
    local count = select("#", ...)
    if count == 0 then
        return
    end
    local has_blob = false
    for index = 1, count do
        if is_blob((select(index, ...))) then
            has_blob = true
            break
        end
    end
    if not has_blob then
        stmt:bind(...)
        return
    end
    for index = 1, count do
        local value = select(index, ...)
        if is_blob(value) then
            bind_blob(stmt, index, value.bytes)
        else
            stmt:bind1(index, value)
        end
    end
end

local function copy_row(row)
    for i = 1, #row do
        local value = row[i]
        if type(value) == "table" and type(value[2]) == "number" then
            -- BLOB: valid only until the next step(), so copy now.
            --
            -- Test the size, not the pointer: SQLite returns a NULL pointer
            -- for a zero-length BLOB and LuaJIT compares a NULL cdata pointer
            -- equal to nil, so `value[1] ~= nil` silently left the {ptr, 0}
            -- wrapper in place and PB.decode later choked on a table.
            local bytes = value[1]
            row[i] = bytes ~= nil and require("ffi").string(bytes, value[2]) or ""
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
    bind_arguments(stmt, ...)
    local rows = {}
    for row in stmt:rows() do
        rows[#rows + 1] = copy_row(row)
    end
    return rows
end

function Conn:first(sql, ...)
    local stmt = self:statement(sql)
    bind_arguments(stmt, ...)
    local row = stmt:step()
    if not row then
        return nil
    end
    return copy_row(row)
end

--- Execute a statement that returns no rows (insert/update/delete).
function Conn:run(sql, ...)
    local stmt = self:statement(sql)
    bind_arguments(stmt, ...)
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
