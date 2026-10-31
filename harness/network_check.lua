--[[--
Exercise the real TLS path inside a KOReader tree (no credentials, no UI).

    cd <koreader tree>
    PLUGIN_DIR=/mnt/d/ankindle/kindlearnki.koplugin \
      ./luajit /mnt/d/ankindle/harness/network_check.lua

This is the closest thing to the device that can run off-device: it uses the
same KOReader `socket` / `ssl` / `socketutil` modules and the same CA bundle as
the plugin's transport, so a broken LuaSec binding, a missing CA, or a bad
option table shows up here instead of on the Kindle.
]]

local plugin_dir = os.getenv("PLUGIN_DIR") or "/mnt/d/ankindle/kindlearnki.koplugin"

require("setupkoenv")

local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(
    DataStorage:getDataDir() .. "/settings.reader.lua")

package.path = plugin_dir .. "/?.lua;" .. package.path

local Transport = require("sync.transport")

print("cafile:", Transport.default_cafile())
local steps = Transport.selftest("sync.ankiweb.net")
local failed = 0
for _, step in ipairs(steps) do
    print(string.format("%s %-28s %s", step.ok and "ok  " or "FAIL", step.stage,
        tostring(step.detail)))
    if not step.ok then
        failed = failed + 1
    end
end

-- A full request path with an invalid key: AnkiWeb answers 403, which proves
-- headers, zstd framing and the response reader all work end to end without
-- touching a real account.
local response, err = Transport.request{
    url = "https://sync.ankiweb.net/sync/meta",
    method = "POST",
    headers = {
        ["anki-sync"] = '{"v":11,"k":"","c":"check,kindlearnki,koreader","s":"abcdef"}',
        ["content-type"] = "application/octet-stream",
        ["content-length"] = "0",
    },
    body = "",
}
if response then
    print(string.format("ok   POST /sync/meta           status=%s bytes=%d",
        tostring(response.status), #(response.body or "")))
else
    failed = failed + 1
    print("FAIL POST /sync/meta           " .. tostring(err))
end

print(string.format("\n%d failure(s)", failed))
os.exit(failed == 0 and 0 or 1)
