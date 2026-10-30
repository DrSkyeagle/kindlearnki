--[[--
Runtime smoke test for the plugin entry point.

    cd <koreader tree>
    PLUGIN_DIR=/mnt/d/ankindle/kindleanki.koplugin \
      xvfb-run -a ./luajit /mnt/d/ankindle/harness/smoke_main.lua

Loads `main.lua` the way KOReader does, instantiates it, and then **calls the
menu actions that touch the UI and the network**.  Static checks cannot see a
missing `require` that only fails when a method runs -- the device log read
"main.lua:345: attempt to index global 'UIManager' (a nil value)" from inside
`busy()` -- so this harness exercises `network_selftest` for real.
]]

local plugin_dir = os.getenv("PLUGIN_DIR") or "/mnt/d/ankindle/kindleanki.koplugin"

require("setupkoenv")

local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(
    DataStorage:getDataDir() .. "/settings.reader.lua")

local Device = require("device")
if Device.init then
    Device:init()
end
if Device.screen and Device.screen.init then
    Device.screen:init()
end
require("document/canvascontext"):init(Device)

package.path = plugin_dir .. "/?.lua;" .. package.path

local Plugin = dofile(plugin_dir .. "/main.lua")

local instance = Plugin:new{
    ui = {
        menu = {
            registerToMainMenu = function() end,
        },
    },
}
local ok_init, init_error = pcall(instance.init, instance)
assert(ok_init, "init() raised: " .. tostring(init_error))
print("SMOKE init ok; caps=" .. tostring(instance.caps and instance.caps.summary))

local ok, result = xpcall(function()
    return instance:network_selftest()
end, debug.traceback)

if not ok then
    print("SMOKE-FAIL network_selftest: " .. tostring(result))
    os.exit(1)
end

print("SMOKE-OK network_selftest returned " .. tostring(result))

-- The device failure was `ljsqlite3[cantopen]`: the plugin data directory did
-- not exist on a fresh install.  Reproduce that situation here (a brand new
-- directory tree) and prove the plugin can write its files inside it.  Opening
-- an *empty* SQLite file is intentionally not done here: that is what bug #2
-- was, and `tests/test_runner.lua` covers the download-then-open sequence.
local Paths = require("core.paths")
local base = "/tmp/kindleanki-smoke-" .. tostring(os.time())
local paths = Paths.new(base, base .. "/settings")
local ok_dirs, dir_err = Paths.ensure(paths)
assert(ok_dirs, "Paths.ensure failed: " .. tostring(dir_err))
local probe = assert(io.open(paths.root .. "/probe.txt", "wb"),
    "cannot write into the freshly created data directory")
probe:write("x")
probe:close()
os.remove(paths.root .. "/probe.txt")
print("SMOKE fresh-directory data dir ok")

-- The typo that broke tapping a deck lived in this helper; call it for real.
local controller = require("study.controller")
local style = controller.card_style()
assert(style and style:find("font-size:", 1, true), "card_style is broken: " .. tostring(style))
print("SMOKE card_style ok: " .. style)
