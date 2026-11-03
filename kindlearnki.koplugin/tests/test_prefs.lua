local Prefs = require("core.prefs")

-- LuaSettings is a KOReader object; the module only needs three of its methods,
-- so a table with those three is a faithful stand-in (and lets the test see
-- exactly what was written).
local function fake_store(initial)
    local store = {
        data = {},
        flushes = 0,
        readSetting = function(self, key)
            return self.data[key]
        end,
        saveSetting = function(self, key, value)
            self.data[key] = value
        end,
        delSetting = function(self, key)
            self.data[key] = nil
        end,
        flush = function(self)
            self.flushes = self.flushes + 1
        end,
    }
    for key, value in pairs(initial or {}) do
        store.data[key] = value
    end
    return store
end

return {
    ["without a settings file the defaults apply"] = function()
        Prefs.attach(nil)
        assert(Prefs.get("study_margin") == Prefs.DEFAULTS.study_margin,
            tostring(Prefs.get("study_margin")))
    end,

    ["an untouched setting reads back as the default"] = function()
        Prefs.attach(fake_store())
        -- 10 is the deck list's margin; the number is pinned because it is what
        -- makes the two screens line up on a fresh install.
        assert(Prefs.get("study_margin") == 10, tostring(Prefs.get("study_margin")))
    end,

    ["a saved value is written through and read back"] = function()
        local store = fake_store()
        Prefs.attach(store)
        assert(Prefs.set("study_margin", 24) == 24)
        assert(store.data.study_margin == 24, tostring(store.data.study_margin))
        -- Flushed at once: the reader is often killed rather than closed.
        assert(store.flushes == 1, tostring(store.flushes))
        assert(Prefs.get("study_margin") == 24)
    end,

    ["values outside the range are clamped"] = function()
        Prefs.attach(fake_store())
        assert(Prefs.set("study_margin", -5) == 0)
        assert(Prefs.get("study_margin") == 0)
        assert(Prefs.set("study_margin", 999) == 40)
        assert(Prefs.get("study_margin") == 40)
    end,

    ["a hand-edited settings file cannot push the card off the screen"] = function()
        Prefs.attach(fake_store({ study_margin = "wide" }))
        assert(Prefs.get("study_margin") == 10, tostring(Prefs.get("study_margin")))
        Prefs.attach(fake_store({ study_margin = 500 }))
        assert(Prefs.get("study_margin") == 40, tostring(Prefs.get("study_margin")))
    end,

    ["reset drops the key so the default applies again"] = function()
        local store = fake_store({ study_margin = 30 })
        Prefs.attach(store)
        assert(Prefs.reset("study_margin") == 10)
        assert(store.data.study_margin == nil)
        assert(store.flushes == 1, tostring(store.flushes))
        assert(Prefs.get("study_margin") == 10)
    end,
}
