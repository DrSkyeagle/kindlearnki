--[[--
User preferences that the self-drawn screens read while they paint.

Only a handful of numbers are exposed, and each one is a *design* value (the
same units `ui/tokens.lua` uses), not a pixel count: the screens run through
`Screen:scaleBySize()` exactly like the rest of the interface, so a value that
looks right on a Voyage also looks right on a 300 dpi Oasis.

`main.lua` hands us the plugin's LuaSettings object once at init; the module
keeps no file path of its own, which is what makes it testable in a bare LuaJIT
(a fake store is just a table with the three LuaSettings methods).
]]

local Tokens = require("ui.tokens")

local Prefs = {}

--- What a key means when the user has never touched it.
Prefs.DEFAULTS = {
    -- Horizontal margin of the study screen, in design units.  The deck list
    -- uses `Tokens.space.margin`, so the default keeps the two screens on the
    -- same vertical line; the setting exists because that line is a taste, not
    -- a fact.
    study_margin = Tokens.space.margin,
}

--- Accepted range per key.  Out-of-range values are clamped, never rejected:
--- a settings file edited by hand must not be able to push the card off screen.
Prefs.LIMITS = {
    study_margin = { min = 0, max = 40 },
}

local store = nil

--- Give the module the plugin's settings file.
-- @tparam table|nil settings a LuaSettings instance (readSetting/saveSetting/flush)
function Prefs.attach(settings)
    store = settings
end

--- The attached settings object, for tests and diagnostics.
function Prefs.store()
    return store
end

local function clamp(key, value)
    local limit = Prefs.LIMITS[key]
    if limit then
        if value < limit.min then
            value = limit.min
        elseif value > limit.max then
            value = limit.max
        end
    end
    return value
end

--- Read a preference, falling back to its default.
-- A missing store (headless host, failed LuaSettings load) is not an error: the
-- screens still paint, they just paint with the defaults.
function Prefs.get(key)
    local default = Prefs.DEFAULTS[key]
    if not store then
        return default
    end
    local value = store:readSetting(key)
    if value == nil then
        return default
    end
    value = tonumber(value)
    if not value then
        return default
    end
    return clamp(key, value)
end

--- Store a preference and flush it to disk immediately.
-- Flushing on every change keeps the "power off without closing" case honest:
-- the reader is used in bed, and KOReader is often killed rather than closed.
function Prefs.set(key, value)
    local default = Prefs.DEFAULTS[key]
    value = tonumber(value)
    if not value then
        value = default
    end
    value = clamp(key, value)
    if store then
        store:saveSetting(key, value)
        store:flush()
    end
    return value
end

--- Drop a preference so the default applies again.
function Prefs.reset(key)
    if store then
        store:delSetting(key)
        store:flush()
    end
    return Prefs.DEFAULTS[key]
end

return Prefs
