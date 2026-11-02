--[[ PagePress switch (core/pagepress.lua).

The bug this pins: KOReader only enables the Voyage's fsr keypad when it started
the session *without* the stock framework (`STOP_FRAMEWORK=yes`).  Launched on
top of a running framework, deviced leaves `fsrkeypadEnable` and friends at 0,
the driver emits nothing, and both page keys are silently dead even though the
widgets installed their bindings.  `PagePress.ensure()` repeats KOReader's own
lipc writes from inside the plugin.

Everything here runs without KOReader: the module takes `{ device, lipc }`.
]]

local Helpers = require("helpers")
local Log = require("core.log")

local function fake_lipc(values)
    local calls = {
        init_ids = {},
        sets = {},
        gets = {},
        closed = 0,
    }
    local function make_handle()
        return {
            get_int_property = function(_, service, name)
                calls.gets[#calls.gets + 1] = service .. "/" .. name
                return values[name]
            end,
            set_int_property = function(_, service, name, value)
                calls.sets[#calls.sets + 1] = string.format("%s/%s=%s", service, name, tostring(value))
                values[name] = value
            end,
            close = function() calls.closed = calls.closed + 1 end,
        }
    end
    return {
        calls = calls,
        init = function(id)
            calls.init_ids[#calls.init_ids + 1] = id
            return make_handle()
        end,
    }
end

local voyage = { model = "KindleVoyage", isKindle = true }
local paperwhite = { model = "KindlePaperWhite4", isKindle = true }

return {
    ["a running framework leaves the keypad off, so the plugin switches it on"] = function()
        local lipc = fake_lipc({ fsrkeypadEnable = 0, fsrkeypadPrevEnable = 0, fsrkeypadNextEnable = 0 })
        local PagePress = Helpers.fresh("core.pagepress")
        local ok, info = PagePress.ensure{ device = voyage, lipc = lipc }

        assert(ok, "ensure() reported failure")
        assert(info.changed, "ensure() did not report the change")
        assert(info.before == "0/0/0", "before = " .. tostring(info.before))
        assert(info.after == "1/1/1", "after = " .. tostring(info.after))
        assert(#lipc.calls.sets == 3, "expected 3 property writes, got " .. #lipc.calls.sets)
        assert(lipc.calls.sets[1] == "com.lab126.deviced/fsrkeypadEnable=1",
            "wrote " .. tostring(lipc.calls.sets[1]))
        assert(lipc.calls.init_ids[1] == "com.lab126.kaf",
            "lipc was opened as " .. tostring(lipc.calls.init_ids[1]))
        assert(lipc.calls.closed == 1, "lipc handle was not closed")
    end,

    ["an already enabled keypad is left alone"] = function()
        local lipc = fake_lipc({ fsrkeypadEnable = 1, fsrkeypadPrevEnable = 1, fsrkeypadNextEnable = 1 })
        local PagePress = Helpers.fresh("core.pagepress")
        local ok, info = PagePress.ensure{ device = voyage, lipc = lipc }

        assert(ok)
        assert(not info.changed, "ensure() rewrote properties that were already 1")
        assert(#lipc.calls.sets == 0, "expected no writes, got " .. #lipc.calls.sets)
        assert(info.after == "1/1/1")
    end,

    ["hardware without the fsr keypad is not an error"] = function()
        local lipc = fake_lipc({})
        local PagePress = Helpers.fresh("core.pagepress")
        local ok, info = PagePress.ensure{ device = paperwhite, lipc = lipc }

        assert(not ok, "a non-Voyage Kindle must not claim the keypad is on")
        assert(info.supported == false, "unsupported hardware was reported as supported")
        assert(#lipc.calls.sets == 3, "the properties should still be attempted and fail quietly")
    end,

    ["a non-Kindle host is skipped entirely"] = function()
        local lipc = fake_lipc({ fsrkeypadEnable = 1 })
        local PagePress = Helpers.fresh("core.pagepress")
        local ok = PagePress.ensure{ device = { model = "Kobo" }, lipc = lipc }

        assert(not ok)
        assert(#lipc.calls.init_ids == 0, "lipc was touched on a non-Kindle host")
    end,

    ["the desktop emulator is skipped, although it calls itself a Kindle"] = function()
        -- KOReader's emulator sets isKindle on the Kindle build; it has no
        -- deviced, so probing lipc there only adds a warning to every run.
        local lipc = fake_lipc({})
        local PagePress = Helpers.fresh("core.pagepress")
        local ok = PagePress.ensure{ device = { model = "Emulator", isKindle = true }, lipc = lipc }

        assert(not ok)
        assert(#lipc.calls.init_ids == 0, "lipc was touched in the emulator")
        assert(PagePress.last.on_kindle == false)
    end,

    ["missing liblipc is a log line, not a crash"] = function()
        local messages = {}
        Log.set_sink(function(level, message)
            messages[#messages + 1] = level .. ": " .. message
        end)
        local PagePress = Helpers.fresh("core.pagepress")
        local ok, info = PagePress.ensure{ device = voyage, lipc = false }
        Log.reset()

        assert(not ok)
        assert(info.lipc == false, "the status should say lipc was missing")
        local found = false
        for _, line in ipairs(messages) do
            if line:find("liblipclua", 1, true) then found = true end
        end
        assert(found, "no log line explains the missing liblipclua")
    end,

    ["a lipc handle that cannot be opened is handled"] = function()
        local lipc = { init = function() return nil end }
        local PagePress = Helpers.fresh("core.pagepress")
        local ok, info = PagePress.ensure{ device = voyage, lipc = lipc }

        assert(not ok)
        assert(info.handle == false)
    end,

    ["properties deviced rejects do not take the plugin down"] = function()
        local lipc = {
            init = function()
                return {
                    get_int_property = function() return 0 end,
                    set_int_property = function() error("com.lab126.deviced is not registered") end,
                    close = function() end,
                }
            end,
        }
        local PagePress = Helpers.fresh("core.pagepress")
        local ok, info = PagePress.ensure{ device = voyage, lipc = lipc }

        assert(not ok, "a refused write must not be reported as success")
        assert(info.after == "0/0/0", "after = " .. tostring(info.after))
    end,

    ["available() only claims the Voyage"] = function()
        local PagePress = Helpers.fresh("core.pagepress")
        assert(PagePress.available{ device = voyage }, "Voyage should be available")
        assert(not PagePress.available{ device = paperwhite }, "Paperwhite has no fsr keypad")
        assert(not PagePress.available{ device = { model = "Kobo" } })
    end,

    ["a no-framework launch is not blamed when our own lipc handle fails"] = function()
        -- STOP_FRAMEWORK=yes: KOReader opened the switch itself and kept a
        -- handle.  If our own lipc.init fails there, that is not a problem the
        -- user has to hear about; the keys already work.
        local lipc = { init = function() return nil end }
        local dev = { model = "KindleVoyage", isKindle = true, framework_lipc_handle = {} }
        local PagePress = Helpers.fresh("core.pagepress")
        local ok, info = PagePress.ensure{ device = dev, lipc = lipc }

        assert(ok, "KOReader already enabled the keypad; ensure() must not fail")
        assert(info.handle == false, "the failed handle should still be recorded")
    end,
}
