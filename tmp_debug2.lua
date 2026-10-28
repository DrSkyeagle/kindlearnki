package.path = "kindleanki.koplugin/?.lua;harness/krsim/common/?.lua;harness/krsim/?.lua;" .. package.path
local ffi = require("ffi")
ffi.loadlib = function(n) return ffi.load(n) end
package.loaded["ffi/posix_h"] = true
do
  local p = "harness/krsim/common/lua-ljsqlite3/init.lua"
  local f = assert(io.open(p, "rb")); local s = f:read("*a"); f:close()
  s = s:gsub("free%s*=%s*C%.free", "free = function() end")
  package.loaded["lua-ljsqlite3/init"] = assert(loadstring(s, "@" .. p))()
end
local Collection = require("model.collection")
local c = Collection.open(os.getenv("KINDLEANKI_TEST_COLLECTION"), { read_only = true })
print("collation ok:", tostring(c.collation), tostring(c.collation_error))
for _, name in ipairs({"fields","templates","notetypes","decks"}) do
  local row = c.conn:first("select sql from sqlite_master where name = ?", name)
  print("== " .. name .. " ==")
  print(row and row[1] or "missing")
end
local ok, err = pcall(function() return c.conn:all("select ord, name from fields where ntid = 576958660353") end)
print("fields query:", ok, err)
local ok2, err2 = pcall(function() return c.conn:first("select count(*) from fields") end)
print("fields count:", ok2, err2)
c:close()
