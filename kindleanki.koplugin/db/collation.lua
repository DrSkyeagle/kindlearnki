-- SQLite's `unicase` collation.
--
-- Schema 18 declares decks.name / notetypes.name / templates.name /
-- fields.name with COLLATE unicase.  SQLite resolves the collation when a
-- statement is *prepared*, so without registering it every query touching
-- those tables fails with "no such collation sequence: unicase" — which is
-- exactly how the previous implementation lost access to its own collection.
--
-- Two hazards, both learned the hard way:
--   1. the C callback must outlive the connection (module-level table below),
--      otherwise the GC collects the cdata and SQLite calls a dangling pointer
--      ("bad callback" takes the whole process down);
--   2. registration must tolerate a host where the symbol is missing; a failure
--      here should degrade to "no collation" instead of breaking plugin load.
--
-- Anki's real collation is Unicode case folding.  A byte-wise ASCII/latin-1
-- fold is enough for the comparisons this plugin performs (deck and field
-- names); it is documented here rather than pretending to be exact.

local Collation = {}

local ffi = require("ffi")

pcall(ffi.cdef, [[
int sqlite3_create_collation_v2(
  void *conn,
  const char *zName,
  int eTextRep,
  void *pArg,
  int (*xCompare)(void*, int, const void*, int, const void*),
  void (*xDestroy)(void*)
);
]])

-- Kept alive for the lifetime of the process.
local callbacks = {}

-- Resolve the sqlite library the same way lua-ljsqlite3 does.  `ffi.C` only
-- sees the process image; the symbol lives in libsqlite3 / sqlite3.dll.
local sqlite_lib
local function load_sqlite()
    if sqlite_lib then
        return sqlite_lib
    end
    if type(ffi.loadlib) == "function" then
        sqlite_lib = ffi.loadlib("sqlite3", "0")
    else
        pcall(require, "ffi/loadlib")
        if type(ffi.loadlib) == "function" then
            sqlite_lib = ffi.loadlib("sqlite3", "0")
        else
            sqlite_lib = ffi.load("sqlite3")
        end
    end
    return sqlite_lib
end

local function fold(value)
    -- Only fold bytes that map 1:1 in latin-1; UTF-8 multi-byte sequences are
    -- compared byte-wise (Japanese and Chinese names are unaffected).
    return (value:gsub("[\65-\90]", function(c)
        return string.char(c:byte() + 32)
    end))
end

local function compare(_, n1, p1, n2, p2)
    local a = fold(ffi.string(p1, n1))
    local b = fold(ffi.string(p2, n2))
    if a < b then
        return -1
    elseif a > b then
        return 1
    end
    return 0
end

--- Install `unicase` on a ljsqlite3 connection (or on a db.conn wrapper).
-- @treturn boolean, string|nil
function Collation.install(conn)
    -- Accept both the raw ljsqlite3 connection (a cdata object, not a table)
    -- and our wrapper around it: the wrapper is what callers hold, the raw one
    -- is what carries `_ptr`.
    local raw = conn
    local ok_ptr, ptr = pcall(function()
        return raw and raw._ptr
    end)
    if (not ok_ptr or ptr == nil) and type(conn) == "table" and conn.db ~= nil then
        raw = conn.db
        ok_ptr, ptr = pcall(function()
            return raw._ptr
        end)
    end
    if not ok_ptr or ptr == nil then
        return false, "not an ljsqlite3 connection"
    end
    local ok, result = pcall(function()
        local callback = ffi.cast(
            "int(*)(void*, int, const void*, int, const void*)", compare)
        callbacks[#callbacks + 1] = callback
        return load_sqlite().sqlite3_create_collation_v2(
            ptr, "unicase", 1, nil, callback, nil)
    end)
    if not ok then
        return false, tostring(result)
    end
    if result ~= 0 then
        return false, "sqlite3_create_collation_v2 returned " .. tostring(result)
    end
    return true
end

return Collation
