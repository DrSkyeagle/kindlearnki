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

The module takes an optional environment (`device`, `lipc`, `shell`) so unit
tests can exercise it without KOReader.
]]

local Log = require("core.log")

local PagePress = {}

PagePress.SERVICE = "com.lab126.deviced"

-- LIPC only lets one process own a client id, and the stock KAF process owns
-- `com.lab126.kaf` for as long as the framework is up.  Opening *that* id on
-- top of a running framework therefore fails on the device (0.3.3 did exactly
-- that and nothing happened on a real Voyage), while it works in an emulator
-- whose harness has stopped lab126_gui.  KOReader's own Kindle port opens
-- `com.github.koreader.*` ids for everything it does next to a live framework,
-- so do the same and keep the KAF id as a last resort for the no-framework
-- launch.
PagePress.CLIENT_ID = "com.github.koreader.kindlearnki"
PagePress.KAF_CLIENT_ID = "com.lab126.kaf"

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

-- The helper binaries speak to the same LIPC bus without claiming a client id,
-- so they still work on firmware that refuses every id from a plugin process.
local function shell_get(name)
    local pipe = io.popen(string.format("lipc-get-prop %s %s 2>/dev/null", PagePress.SERVICE, name), "r")
    if not pipe then
        return nil
    end
    local output = pipe:read("*a")
    pipe:close()
    return tonumber(tostring(output or ""):match("^%s*(-?%d+)"))
end

local function shell_set(name)
    local status = os.execute(string.format(
        "lipc-set-prop %s %s 1 >/dev/null 2>&1", PagePress.SERVICE, name))
    -- LuaJIT returns the exit status (0 == success); keep a boolean path too.
    return status == true or status == 0
end

local function open_lipc(lipc)
    for _, id in ipairs({ PagePress.CLIENT_ID, PagePress.KAF_CLIENT_ID }) do
        local ok, handle = pcall(lipc.init, id)
        if ok and handle then
            return handle, id
        end
    end
    return nil
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
-- @tparam[opt] table env `{ device = <KOReader device>, lipc = <liblipclua>, shell = { get, set } }`
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

    local handle, client_id = open_lipc(lipc)

    local transport
    local get, set
    if handle then
        transport = "lipc"
        get = function(name) return get_int(handle, name) end
        set = function(name) return set_int(handle, name) end
        if client_id ~= PagePress.CLIENT_ID then
            Log.dbg("page buttons: lipc opened as " .. client_id .. " (own id refused)")
        end
    else
        local sh = env.shell
        if sh == nil then
            sh = { get = shell_get, set = shell_set }
        end
        transport = "shell"
        get = sh.get
        set = sh.set
    end

    local before = {}
    for i, name in ipairs(PagePress.PROPERTIES) do
        before[i] = get(name)
    end

    local after = {}
    local changed = false
    local failed = false
    for i, name in ipairs(PagePress.PROPERTIES) do
        if before[i] == 1 then
            after[i] = 1
        elseif set(name) then
            after[i] = 1
            changed = true
        else
            after[i] = before[i]
            failed = true
        end
    end

    if handle then
        pcall(handle.close, handle)
    end

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
        transport = transport,
        client = client_id,
        before = describe(before),
        after = describe(after),
        changed = changed,
        supported = known,
    }
    PagePress.last = info

    if not known then
        if transport == "shell" then
            -- Neither a client id nor the helper binaries reached deviced: that
            -- is a real problem on the one model this feature exists for.
            if dev.framework_lipc_handle ~= nil then
                Log.dbg("page buttons: no handle, KOReader switched the keypad on already")
                return true, info
            end
            Log.warn("page buttons: could not reach com.lab126.deviced, cannot enable the PagePress rocker")
            return false, info
        end
        Log.dbg("page buttons: this Kindle has no deviced fsr keypad")
        return false, info
    elseif failed then
        Log.warn("page buttons: deviced did not accept every property (" ..
            info.before .. " -> " .. info.after .. ") via " .. transport)
        return false, info
    elseif changed then
        local how = transport == "lipc" and "" or " via lipc-set-prop"
        -- Once per launch at info level; the log is how a key report gets
        -- diagnosed without shell access.
        Log.info("page buttons: enabled deviced keypad" .. how ..
            " (" .. info.before .. " -> " .. info.after .. ")")
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
