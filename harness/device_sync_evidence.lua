--[[--
Gather proof that AnkiWeb really holds this device's reviews.

Runs INSIDE the running KOReader (via the http inspector's dofile entry point),
because only that process can `require("ssl.https")`.  It downloads the server
copy with the plugin's own client, opens it read-only and compares row counts
and timestamps with the local collection.  Only numbers leave the device.

    # on the development host
    curl "http://<kindle>:8080/koreader/globals/dofile/%22/tmp/device_sync_evidence.lua%22"

A healthy post-sync report looks like

    server:cards=1982,notes=1940,revlog=1588,decks=55,... | local:cards=1982,... | equal_rows=true

`equal_rows=true` means the 3 reviews the device pushed survived the
`sanityCheck2` comparison and are on the server (the revlog count is the
sharpest signal: it only grows by the reviews this device made).

--]]

-- Proof that the server really has our reviews, run on the device.
--
-- Downloads the server copy with the plugin's own client, opens it read-only
-- and compares its row counts / timestamps with the local collection.  Only
-- numbers leave the device (no hkey, no note text), through the dev host's
-- http access log.
local host = "192.168.0.136:8000"
local ko = "/mnt/us/koreader"
local local_path = ko .. "/kindleanki/collection.anki2"
local settings_path = ko .. "/settings/kindleanki.lua"

package.path = ko .. "/plugins/kindleanki.koplugin/?.lua;"
    .. ko .. "/common/?.lua;" .. ko .. "/frontend/?.lua;" .. package.path

local function report(text)
    local url = "http://" .. host .. "/evidence?v="
        .. (text:gsub("[^%w%-%._~=:,]", function(c)
            return string.format("%%%02X", string.byte(c))
        end))
    os.execute("wget -q -O /dev/null '" .. url .. "'")
end

local settings = dofile(settings_path) or {}
local hkey = settings.hkey
if not hkey or hkey == "" then
    report("no-hkey")
    return
end

local Client = require("sync.client")
local Transport = require("sync.transport")
local Collection = require("model.collection")

local client = Client.new{ transport = Transport, hkey = hkey }
local ok, err = client:resolve_host()
if not ok then
    report("resolve_failed:" .. tostring(err))
    return
end

local meta = client:meta()
if not meta then
    report("meta_failed")
    return
end

local body = client:download()
if not body then
    report("download_failed")
    return
end

local server_path = "/tmp/server-copy.anki2"
local file = assert(io.open(server_path, "wb"))
file:write(body)
file:close()

local function counts(path)
    local collection = Collection.open(path, { read_only = true })
    local function count(sql)
        local row = collection.conn:first(sql)
        return tonumber(row and row[1]) or 0
    end
    local out = {
        cards = count("select count(*) from cards"),
        notes = count("select count(*) from notes"),
        revlog = count("select count(*) from revlog"),
        decks = count("select count(*) from decks"),
        mod = count("select mod from col"),
        usn = count("select usn from col"),
        scm = count("select scm from col"),
    }
    collection:close()
    return out
end

local server = counts(server_path)
local local_copy = counts(local_path)

report(string.format(
    "server:cards=%d,notes=%d,revlog=%d,decks=%d,mod=%d,usn=%d | local:cards=%d,notes=%d,revlog=%d,decks=%d,mod=%d,usn=%d | equal_rows=%s",
    server.cards, server.notes, server.revlog, server.decks, server.mod, server.usn,
    local_copy.cards, local_copy.notes, local_copy.revlog, local_copy.decks,
    local_copy.mod, local_copy.usn,
    tostring(server.cards == local_copy.cards
        and server.notes == local_copy.notes
        and server.revlog == local_copy.revlog)))

os.remove(server_path)
os.remove(server_path .. "-wal")
os.remove(server_path .. "-shm")
