local Version = require("core.version")
local Helpers = require("helpers")

return {
    ["VERSION looks like a release version"] = function()
        assert(type(Version.VERSION) == "string")
        assert(Version.VERSION:match("^%d+%.%d+%.%d+"), Version.VERSION)
    end,

    ["_meta.lua advertises the same version"] = function()
        local meta = dofile(Helpers.root .. "/_meta.lua")
        assert(type(meta) == "table")
        assert(type(meta.fullname) == "string")
        assert(meta.fullname:find(Version.VERSION, 1, true), meta.fullname)
    end,

    ["_meta.lua does not set name (it comes from the directory)"] = function()
        local meta = dofile(Helpers.root .. "/_meta.lua")
        assert(meta.name == nil, "PluginLoader ignores name and warns")
    end,

    ["main.lua derives its version from core.version"] = function()
        assert(Helpers.contains("main.lua", "KindleAnki.VERSION = Version.VERSION"))
    end,
}
