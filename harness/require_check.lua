--[[--
Require plugin modules inside a real KOReader tree and report the first error.

    cd <koreader tree>
    PLUGIN_DIR=/mnt/d/ankindle/kindlearnki.koplugin \
      ./luajit /mnt/d/ankindle/harness/require_check.lua [module ...]

With no module arguments it checks the whole plugin surface, including the UI
modules that only exist on a host with Screen/CanvasContext.  This is the check
that would have caught "登录界面不可用" (a `require` of a widget that does not
exist in this KOReader release) before it reached the device.
]]

local plugin_dir = os.getenv("PLUGIN_DIR") or "/mnt/d/ankindle/kindlearnki.koplugin"

require("setupkoenv")

local DataStorage = require("datastorage")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(
    DataStorage:getDataDir() .. "/settings.reader.lua")

local Device = require("device")
if Device.init then
    Device:init()
end
local Screen = Device.screen
if Screen.init then
    Screen:init()
end
require("document/canvascontext"):init(Device)

package.path = plugin_dir .. "/?.lua;" .. package.path

local default_modules = {
    "core.version",
    "core.log",
    "core.paths",
    "core.capabilities",
    "core.pagepress",
    "core.trace",
    "proto.pb",
    "proto.encode",
    "db.conn",
    "db.collation",
    "model.collection",
    "sched.config",
    "sched.timing",
    "sched.states",
    "sched.queue",
    "sched.answer",
    "render.template",
    "render.sanitize",
    "sync.json",
    "sync.zstd",
    "sync.protocol",
    "sync.client",
    "sync.store",
    "sync.runner",
    "sync.transport",
    "study.session",
    "study.decklist",
    "study.controller",
    "ui.tokens",
    "ui.widgets",
    "ui.deckview",
    "ui.studyview",
    "ui.login",
}

local modules = { ... }
if #modules == 0 then
    modules = default_modules
end

local failures = 0
for _, name in ipairs(modules) do
    local ok, err = pcall(require, name)
    if ok then
        print(string.format("ok    %s", name))
    else
        failures = failures + 1
        print(string.format("FAIL  %s\n      %s", name, tostring(err)))
    end
end

print(string.format("\n%d module(s) checked, %d failed", #modules, failures))
os.exit(failures == 0 and 0 or 1)
