--[[-- Kindle PagePress (WhisperTouch) buttons under a running framework.

On a Voyage the capacitive page-turn sensors are only reported by the kernel
driver while `deviced` has these three properties set to 1:

    fsrkeypadEnable, fsrkeypadPrevEnable, fsrkeypadNextEnable

KOReader switches them on itself, but only when it started the session by
stopping the stock framework (`STOP_FRAMEWORK=yes`); the handle it uses is
`Device.framework_lipc_handle`, which is nil whenever lab126_gui is still
running (frontend/device/kindle/device.lua, KindleVoyage:init).  In that launch
mode deviced leaves the properties at 0, no KEY_PAGEUP / KEY_PAGEDOWN ever
reaches /dev/input/event2, and every key binding in this plugin *looks*
installed while the rocker does nothing at all.

`ensure()` repeats what KOReader does, from inside the plugin, so the buttons
work in both launch modes.  It is a no-op off Kindle, when liblipc is missing,
and when the values are already 1.

The module takes an optional environment (`device`, `lipc`) so unit tests can
exercise it without KOReader.
]]

local Log = require("core.log")

local PagePress = {}

PagePress.SERVICE = "com.lab126.deviced"

PagePress.PROPERTIES = {
    "fsrkeypadEnable",
    "fsrkeypadPrevEnable",
    "fsrkeypadNextEnable",
}

--- Last attempt, for the log line and for debugging: { on_kindle, lipc, before, after, changed }.
PagePress.last = nil

local function is_kindle(dev)
    if type(dev) ~= "table" then
        return false
    end
    -- The desktop emulator runs the Kindle build with `isKindle = true`, but it
    -- has no deviced and no rocker; talking to lipc there is pure noise.
    local model = tostring(dev.model or "")
    if dev.is_emulator or model == "Emulator" then
        return false
    end
    if dev.isKindle then
        return true
    end
    return model:sub(1, 6) == "Kindle"
end

local function get_int(handle, name)
    local ok, value = pcall(handle.get_int_property, handle, PagePress.SERVICE, name)
    if not ok then
        return nil
    end
    value = tonumber(value)
    return value
end

local function set_int(handle, name)
    -- liblipclua raises when the service is not registered; one bad property
    -- must not stop the other two from being set.
    return (pcall(handle.set_int_property, handle, PagePress.SERVICE, name, 1))
end

local function describe(state)
    local parts = {}
    for i, name in ipairs(PagePress.PROPERTIES) do
        local value = state[i]
        parts[i] = value == nil and "?" or tostring(value)
    end
    return table.concat(parts, "/")
end

--- Make sure the PagePress rocker can deliver key events on this device.
--
-- Cheap enough to call from every screen that binds PagePress: it is four lipc
-- property operations and they are idempotent.
--
-- @tparam[opt] table env `{ device = <KOReader device>, lipc = <liblipclua> }`
-- @treturn boolean ok  true when the keypad is (or already was) enabled
-- @treturn table|nil info  see `PagePress.last`
function PagePress.ensure(env)
    env = env or {}

    local dev = env.device
    if dev == nil then
        local loaded, module = pcall(require, "device")
        dev = loaded and module or nil
    end
    if not is_kindle(dev) then
        PagePress.last = { on_kindle = false }
        return false, PagePress.last
    end

    local lipc = env.lipc
    if lipc == nil then
        local loaded, module = pcall(require, "liblipclua")
        lipc = loaded and module or nil
    end
    if not lipc then
        PagePress.last = { on_kindle = true, lipc = false }
        Log.warn("page buttons: liblipclua is missing, cannot enable the PagePress rocker")
        return false, PagePress.last
    end

    local handle
    do
        local ok, result = pcall(lipc.init, "com.lab126.kaf")
        if ok and result then
            handle = result
        end
    end
    if not handle then
        PagePress.last = { on_kindle = true, lipc = true, handle = false }
        if dev.framework_lipc_handle ~= nil then
            -- No-framework launch: KOReader opened the switch itself in
            -- KindleVoyage:init, so a missing handle of our own is not news.
            Log.dbg("page buttons: no lipc handle, KOReader switched the keypad on already")
            return true, PagePress.last
        end
        Log.warn("page buttons: could not open a lipc handle, cannot enable the PagePress rocker")
        return false, PagePress.last
    end

    local before = {}
    for i, name in ipairs(PagePress.PROPERTIES) do
        before[i] = get_int(handle, name)
    end

    local after = {}
    local changed = false
    local failed = false
    for i, name in ipairs(PagePress.PROPERTIES) do
        if before[i] == 1 then
            after[i] = 1
        elseif set_int(handle, name) then
            after[i] = 1
            changed = true
        else
            after[i] = before[i]
            failed = true
        end
    end

    pcall(handle.close, handle)

    -- A Kindle without the fsr keypad (Paperwhite, Basic, ...) does not register
    -- the properties at all: reading them yields nil and writing them raises.
    -- That is not an error, it just means this model has no rocker to enable.
    local known = false
    for i = 1, #before do
        if before[i] ~= nil then
            known = true
        end
    end

    local info = {
        on_kindle = true,
        lipc = true,
        before = describe(before),
        after = describe(after),
        changed = changed,
        supported = known,
    }
    PagePress.last = info

    if not known then
        Log.dbg("page buttons: this Kindle has no deviced fsr keypad")
        return false, info
    elseif failed then
        Log.warn("page buttons: deviced did not accept every property (" ..
            info.before .. " -> " .. info.after .. ")")
        return false, info
    elseif changed then
        -- Once per launch at info level; the log is how a key report gets
        -- diagnosed without shell access.
        Log.info("page buttons: enabled deviced keypad (" .. info.before .. " -> " .. info.after .. ")")
    else
        Log.dbg("page buttons: deviced keypad already enabled (" .. info.after .. ")")
    end
    return true, info
end

--- True when this device has a PagePress rocker this plugin can enable.
--
-- Only the Voyage is wired for the fsr keypad in KOReader's Kindle port
-- (KindleVoyage:init is the only model that touches these properties).
function PagePress.available(env)
    env = env or {}
    local dev = env.device
    if dev == nil then
        local loaded, module = pcall(require, "device")
        dev = loaded and module or nil
    end
    if not is_kindle(dev) then
        return false
    end
    return tostring(dev.model or "") == "KindleVoyage"
end

return PagePress
