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
c:load_decks()
print("created", type(c.created), tostring(c.created))
local nconf = 0; for k in pairs(c.deck_configs) do nconf = nconf + 1 end
print("decks", #c.decks, "configs", nconf)
print("active", tostring(c:active_deck_id()), type(c:active_deck_id()))
local ids = c:deck_subtree_ids(c:active_deck_id())
print("subtree count", #ids)
local cards = c:cards_in_decks(ids)
print("cards", #cards)
local n = c.conn:first("select count(*) from cards")
print("all cards", tostring(n[1]))
for i = 1, math.min(5, #c.decks) do
  local dk = c.decks[i]
  print("deck", tostring(dk.id), "conf", tostring(dk.config_id), "name len", #dk.name)
end
c:close()
