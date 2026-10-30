-- Real end-to-end full download against AnkiWeb, using the plugin's own client.
--
--   HKEY=<host key> cd <koreader tree> && ./luajit /mnt/d/ankindle/harness/real_download.lua
--
-- This is the same code path as the device: resolve_host (meta + 308) →
-- download (zstd) → write → open the SQLite file.  It is the closest possible
-- verification off-device, short of the armv7 binary.
local plugin_dir = os.getenv("PLUGIN_DIR") or "/mnt/d/ankindle/kindleanki.koplugin"
local hkey = assert(os.getenv("HKEY"), "HKEY is required")

require("setupkoenv")
local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(
    DataStorage:getDataDir() .. "/settings.reader.lua")
package.path = plugin_dir .. "/?.lua;" .. package.path

local Client = require("sync.client")
local Transport = require("sync.transport")
local Collection = require("model.collection")

local client = Client.new{ transport = Transport, hkey = hkey }
local ok, err = client:resolve_host()
assert(ok, "resolve_host failed: " .. tostring(err))
print("endpoint:", client.endpoint)

local started = os.time()
local bytes, download_error = client:download()
assert(bytes, "download failed: " .. tostring(download_error))
print(string.format("downloaded %d bytes in %ds", #bytes, os.time() - started))

local target = "/tmp/real-collection.anki2"
local file = assert(io.open(target, "wb"))
file:write(bytes)
file:close()

local collection = Collection.open(target)
local row = collection.conn:first("select count(*) from cards")
print("cards:", row and tonumber(row[1]))
local notes = collection.conn:first("select count(*) from notes")
print("notes:", notes and tonumber(notes[1]))
collection:close()
os.remove(target)
os.remove(target .. "-wal")
os.remove(target .. "-shm")
print("REAL-DOWNLOAD-OK")
