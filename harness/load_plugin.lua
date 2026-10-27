--[[--
Load the plugin inside a real KOReader tree, without a display.

    cd <koreader tree>            # the directory holding setupkoenv.lua
    ./luajit /mnt/d/ankindle/harness/load_plugin.lua

Purpose: prove that the plugin's modules resolve, that `init()` survives a
host probe, and that both menu entries are built with the expected submenu.
This is the cheapest check that catches "installed but invisible" failures,
which KOReader otherwise only reports as one line in crash.log.

Exit code 0 on success; any assertion failure exits non-zero.
]]

local plugin_dir = os.getenv("PLUGIN_DIR") or "/mnt/d/ankindle/kindleanki.koplugin"

require("setupkoenv")

-- The same two globals reader.lua installs before anything may require
-- `device`: the SDL device reads settings during probe, so without these the
-- load fails with "attempt to index global 'G_reader_settings'".
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(
    DataStorage:getDataDir() .. "/settings.reader.lua")

package.path = plugin_dir .. "/?.lua;" .. package.path

local Plugin = dofile(plugin_dir .. "/main.lua")

local menu_items = {}
local fake_ui = {
    menu = {
        registerToMainMenu = function(_, plugin)
            plugin:addToMainMenu(menu_items)
        end,
    },
}

local instance = Plugin:new{ ui = fake_ui }
instance:init()

assert(menu_items.kindleanki, "tools-tab menu entry missing")
assert(menu_items.kindleanki_main, "main-tab menu entry missing")
assert(type(menu_items.kindleanki.sub_item_table) == "table", "submenu missing")
assert(#menu_items.kindleanki.sub_item_table == 4, "expected 4 submenu items")

-- Every menu label must be a string; calling text_func is what KOReader does.
for index, item in ipairs(menu_items.kindleanki.sub_item_table) do
    assert(type(item.text) == "string" and item.text ~= "",
        "menu item " .. index .. " has no text")
    assert(type(item.callback) == "function",
        "menu item " .. index .. " has no callback")
end

print("LOAD-OK version=" .. tostring(Plugin.VERSION))
print("CAPS " .. tostring(instance.caps and instance.caps.summary))
print("DATA " .. tostring(instance.paths and instance.paths.root))
