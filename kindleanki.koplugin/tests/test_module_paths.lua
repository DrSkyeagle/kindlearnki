-- Guard against module paths that exist in some KOReader releases but not in
-- the one this plugin targets.
--
-- The device run reported "登录界面不可用": `ui/widget/centercontainer` used to
-- be a top-level widget and was moved to `ui/widget/container/`.  A unit test
-- cannot require KOReader modules, so the cheapest guard is checking the source
-- for known-moved paths.  harness/require_check.lua covers the real load, but
-- only when someone runs it against a KOReader tree.

local Helpers = require("helpers")

return {
    ["login uses the container/centercontainer path"] = function()
        local source = Helpers.read("ui/login.lua")
        assert(not source:find('require("ui/widget/centercontainer")', 1, true),
            "the old ui/widget/centercontainer path is back (missing in v2026.07)")
        assert(source:find('require("ui/widget/container/centercontainer")', 1, true),
            "login no longer requires the centring container it needs")
    end,

    ["the login dialog is opaque"] = function()
        local source = Helpers.read("ui/login.lua")
        assert(source:find("background = Blitbuffer.COLOR_WHITE", 1, true),
            "the dialog frame lost its paper background; the card shows through")
    end,
}
