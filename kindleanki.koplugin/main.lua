--[[--
Kindle Anki — KOReader plugin entry point.

This file is deliberately thin.  It owns three things and nothing else:

  * the menu entries and the dispatcher actions,
  * the one-time host probe (see `core/capabilities.lua`),
  * the wiring between those and the screens.

Everything heavy lives in modules that unit tests can load without KOReader:
`db/`, `sched/`, `render/`, `sync/`, `ui/`.

A plugin whose `init()` raises is invisible: KOReader drops the instance and
writes one line to crash.log, so the user sees "the plugin is installed but
there is no menu entry".  Therefore nothing in `init()` is allowed to throw.
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
-- Required here, not looked up as a global: KOReader does not put UIManager in
-- _G, so `UIManager:show(...)` in this file used to crash every menu action
-- that showed a banner (the device log read "attempt to index global
-- 'UIManager' (a nil value)").
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local Version = require("core.version")
local Log = require("core.log")
local Paths = require("core.paths")
local Trace = require("core.trace")
local Capabilities = require("core.capabilities")
local Probe = require("ui.probe")

local KindleAnki = WidgetContainer:extend{
    name = "kindleanki",
    is_doc_only = false,
}

KindleAnki.VERSION = Version.VERSION

--[[ UI widgets are required lazily, for two reasons:

  1. `ui/widget/infomessage` pulls in `ui/font`, which needs a live Screen and
     CanvasContext.  A plugin that requires it at load time cannot be loaded by
     a headless host (and pays for font enumeration on every startup).
  2. A failure to show a message must never propagate into a menu callback.
]]
local function show_message(text)
    local ok_info, InfoMessage = pcall(require, "ui/widget/infomessage")
    if not ok_info then
        Log.err("cannot load infomessage:", InfoMessage)
        return false
    end
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if not ok_ui then
        Log.err("cannot load uimanager:", UIManager)
        return false
    end
    UIManager:show(InfoMessage:new{ text = text })
    return true
end

-- Two tabs, for the same reason the old plugin used two: the tools tab appends
-- plugin entries below "More tools", where people scroll past them.  These ids
-- exist in KOReader's reader/filemanager menu orders; a hint that matches
-- nothing makes the whole main menu fail to build.
KindleAnki.MENU_ENTRIES = {
    { key = "kindleanki", hint = "tools" },
    { key = "kindleanki_main", hint = "main" },
}

KindleAnki.DISPATCHER_ACTIONS = {
    {
        name = "kindleanki_study",
        event = "KindleAnkiStudy",
        title = _("Kindle Anki：开始复习"),
    },
    {
        name = "kindleanki_sync",
        event = "KindleAnkiSync",
        title = _("Kindle Anki：立即同步"),
    },
}

--==========================================================================
-- Lifecycle
--==========================================================================

function KindleAnki:init()
    Log.set_sink(function(level, message)
        local text = Log.PREFIX .. ": " .. message
        if level == "err" and type(logger.err) == "function" then
            logger.err(text)
        elseif level == "warn" and type(logger.warn) == "function" then
            logger.warn(text)
        elseif level == "dbg" and type(logger.dbg) == "function" then
            logger.dbg(text)
        elseif type(logger.info) == "function" then
            logger.info(text)
        else
            print(text)
        end
    end)

    local ok, err = pcall(function()
        self.paths = Paths.for_koreader()
        -- First run on a device: SQLite cannot create the collection inside a
        -- missing directory, and the failure surfaces as a bare `cantopen`.
        local ok_dirs, dir_error = Paths.ensure(self.paths)
        if not ok_dirs then
            Log.err("cannot create data directory:", dir_error)
        else
            Log.info("data directory ready:", self.paths.root)
        end
        self.caps = Capabilities.probe{
            ca_path = self.paths.ca_bundle,
        }
        Log.info(self.caps.summary)
        -- If the previous run died in a native call, its log tail may have been
        -- lost; the breadcrumb file always survives.
        Trace.init(self.paths.root)
        local previous = Trace.last()
        if previous then
            Log.warn("previous run stopped at:", previous)
        end
        if not self.caps.ok then
            Log.err("host is missing capabilities:", table.concat(self.caps.missing, ","))
        end
    end)
    if not ok then
        Log.err("init failed:", err)
        self.caps = {
            values = {},
            missing = {},
            ok = false,
            summary = "init failed: " .. tostring(err),
        }
        self.paths = nil
    end

    pcall(self.register_dispatcher_actions, self)
    pcall(self.register_menu, self)
end

--- Register the plugin's menu tree.  Split out so `init()` can keep a single
--- pcall around the environment work and still survive a menu failure.
function KindleAnki:register_menu()
    local menu = self.ui and self.ui.menu
    if not menu or type(menu.registerToMainMenu) ~= "function" then
        Log.warn("no main menu on self.ui; the plugin will have no menu entry")
        return false
    end
    local ok, err = pcall(menu.registerToMainMenu, menu, self)
    if not ok then
        Log.err("registerToMainMenu failed:", err)
        return false
    end
    return true
end

-- `dispatcher` is required lazily: it pulls in the file manager, and the plugin
-- itself is loaded from inside FileManager:init(), so a top-level require would
-- be a load loop.
function KindleAnki:register_dispatcher_actions()
    local ok, Dispatcher = pcall(require, "dispatcher")
    if not ok or type(Dispatcher) ~= "table" then
        Log.dbg("dispatcher not available")
        return false
    end
    -- `_index`, not `_`: a bare `_` loop variable shadows gettext's `_`, and
    -- the first call to `_("...")` inside the loop then dies with
    -- "attempt to call local '_' (a number value)".  KOReader catches that in
    -- registerToMainMenu and only logs it, so the plugin would look installed
    -- but never appear in any menu.
    for action_index, action in ipairs(KindleAnki.DISPATCHER_ACTIONS) do
        pcall(function()
            Dispatcher:registerAction(action.name, {
                category = "none",
                event = action.event,
                title = action.title,
                general = true,
            })
        end)
    end
    return true
end

function KindleAnki:onDispatcherRegisterActions()
    self:register_dispatcher_actions()
end

--==========================================================================
-- Menu
--==========================================================================

function KindleAnki:build_submenu()
    return {
        {
            text = _("开始复习"),
            callback = function()
                self:onKindleAnkiStudy()
            end,
        },
        {
            text = _("立即同步"),
            callback = function()
                self:onKindleAnkiSync()
            end,
        },
        {
            text = _("诊断"),
            callback = function()
                self:show_diagnostics()
            end,
        },
        {
            text = _("网络诊断"),
            callback = function()
                self:network_selftest()
            end,
        },
        {
            text = _("关于"),
            callback = function()
                self:show_about()
            end,
        },
    }
end

function KindleAnki:addToMainMenu(menu_items)
    for entry_index, entry in ipairs(KindleAnki.MENU_ENTRIES) do
        menu_items[entry.key] = {
            text = _("Kindle Anki"),
            sorting_hint = entry.hint,
            sub_item_table = self:build_submenu(),
        }
    end
end

--==========================================================================
-- Collection lifecycle
--==========================================================================

local function file_exists(path)
    local file = io.open(path, "rb")
    if file then
        file:close()
        return true
    end
    return false
end

--- Open the local collection on demand.
-- Opening at plugin load would lock the file for the whole KOReader session and
-- would make "the plugin failed to load" indistinguishable from "the database
-- is locked", so it happens when a screen actually needs it.
function KindleAnki:open_collection()
    if self.collection then
        return self.collection
    end
    if not self.paths then
        return nil, "插件未初始化（路径不可用）"
    end
    local ok_dirs, dir_error = Paths.ensure(self.paths)
    if not ok_dirs then
        return nil, "无法创建数据目录：" .. tostring(dir_error)
    end
    if not file_exists(self.paths.collection) then
        return nil, "还没有本地库：请先登录并同步一次"
    end
    local ok, collection = pcall(function()
        local Model = require("model.collection")
        return Model.open(self.paths.collection)
    end)
    if not ok then
        Log.err("open collection failed:", collection)
        return nil, "打开本地库失败：" .. tostring(collection)
    end
    self.collection = collection
    return collection
end

function KindleAnki:close_collection()
    if self.collection then
        pcall(self.collection.close, self.collection)
        self.collection = nil
    end
end

--==========================================================================
-- Actions
--==========================================================================

function KindleAnki:onKindleAnkiStudy()
    local collection, err = self:open_collection()
    if not collection then
        show_message(tostring(err))
        return true
    end

    local ok, result = xpcall(function()
        local Controller = require("study.controller")
        return Controller.show_decks(collection)
    end, debug.traceback)
    if not ok then
        Log.err("study screen failed:", result)
        show_message(_("打开复习界面失败，详情见 crash.log。"))
    end
    return true
end

--==========================================================================
-- Sync
--==========================================================================

function KindleAnki:settings()
    if self.lua_settings then
        return self.lua_settings
    end
    if not self.paths then
        return nil
    end
    local ok, LuaSettings = pcall(require, "luasettings")
    if not ok then
        return nil
    end
    self.lua_settings = LuaSettings:open(self.paths.settings_file)
    return self.lua_settings
end

function KindleAnki:read_setting(key, default)
    local settings = self:settings()
    if not settings then
        return default
    end
    local value = settings:readSetting(key)
    if value == nil then
        return default
    end
    return value
end

function KindleAnki:save_setting(key, value)
    local settings = self:settings()
    if not settings then
        return
    end
    settings:saveSetting(key, value)
    settings:flush()
end

function KindleAnki:build_client()
    local Client = require("sync.client")
    local Transport = require("sync.transport")
    return Client.new{
        endpoint = self:read_setting("endpoint", "https://sync.ankiweb.net/"),
        hkey = self:read_setting("hkey", ""),
        client_version = Version.VERSION,
        transport = Transport,
    }
end

--[[ A blocking network call on a single-core e-ink device needs a visible
"please wait" and must not be clamped by the power manager; both are handled
here, and the closer is idempotent because error paths call it twice. ]]
function KindleAnki:busy(message)
    local InfoMessage = require("ui/widget/infomessage")
    local banner = InfoMessage:new{ text = message }
    UIManager:show(banner)
    UIManager:forceRePaint()
    pcall(UIManager.preventStandby, UIManager)
    local released = false
    return function()
        if released then
            return
        end
        released = true
        pcall(UIManager.close, UIManager, banner)
        pcall(UIManager.allowStandby, UIManager)
    end
end

function KindleAnki:prompt_login(then_sync)
    local ok, Login = pcall(require, "ui.login")
    if not ok then
        show_message("登录界面不可用：" .. tostring(Login))
        return
    end
    local started, err = pcall(Login.start, {
        on_submit = function(email, password)
            Log.info("login: submit received, len(email)=" .. tostring(#email))
            --[[ The request runs one tick after the dialog closes: tearing the
            keyboard down and starting a blocking TLS handshake in the same
            callback is the one thing that differs from every KOReader dialog,
            and any native crash in the TLS stack must happen *after* the UI has
            settled so the last line in crash.log still tells us which stage
            ran. ]]
            Trace.mark("login.submit")
            UIManager:scheduleIn(0.3, function()
                -- Free everything the closed dialogs/keyboard left behind
                -- before a TLS handshake on a 512 MB device.
                collectgarbage("collect")
                collectgarbage("collect")
                Log.info(string.format("login: memory before request %.1f MB",
                    collectgarbage("count") / 1024))
                local finished, failure = xpcall(function()
                    Log.info("login: host_key begin")
                    Trace.mark("login.request.start")
                    local done = self:busy(_("正在登录 AnkiWeb…"))
                    local client = self:build_client()
                    local hkey, login_error = client:host_key(email, password)
                    Trace.mark("login.request.done")
                    done()
                    Log.info(string.format("login: memory after request %.1f MB",
                        collectgarbage("count") / 1024))
                    Log.info("login: host_key returned",
                        hkey and "ok" or ("error=" .. tostring(login_error)))
                    if not hkey then
                        show_message(_("登录失败：") .. tostring(login_error))
                        return
                    end
                    self:save_setting("hkey", hkey)
                    show_message(_("登录成功。"))
                    if then_sync then
                        self:run_sync()
                    end
                end, debug.traceback)
                if not finished then
                    Log.err("login: callback failed:", failure)
                    show_message(_("登录过程出错，详情见 crash.log。"))
                end
            end)
        end,
    })
    if not started then
        Log.err("cannot start login dialog:", err)
        show_message(_("无法打开登录界面，详情见 crash.log。"))
    end
end

--- Reachability probe for the "网络诊断" menu entry.
--
-- Everything is logged stage by stage; the device cannot be debugged from here,
-- so the user runs this once and sends crash.log.
function KindleAnki:network_selftest()
    local ok, Transport = pcall(require, "sync.transport")
    if not ok then
        show_message("网络诊断不可用：" .. tostring(Transport))
        return true
    end

    collectgarbage("collect")
    Log.info(string.format("selftest: memory %.1f MB", collectgarbage("count") / 1024))
    Trace.mark("selftest.start")
    local done = self:busy(_("正在测试网络…"))
    local steps = Transport.selftest("sync.ankiweb.net")
    Trace.mark("selftest.done")
    done()

    local lines = { _("网络诊断结果：") }
    local all_ok = true
    for _, step in ipairs(steps) do
        lines[#lines + 1] = string.format("%s %s（%s）",
            step.ok and "✓" or "✗", step.stage, tostring(step.detail))
        if not step.ok then
            all_ok = false
        end
    end
    if all_ok then
        lines[#lines + 1] = ""
        lines[#lines + 1] = _("网络与证书校验正常。")
    end
    show_message(table.concat(lines, "\n"))
    return true
end

--- Ask which side wins when the schema differs.
function KindleAnki:prompt_full_sync(reason)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = string.format("%s\n\n%s", _("需要整库同步"), tostring(reason or "")),
        buttons = {
            {
                {
                    text = _("下载云端覆盖本地"),
                    callback = function()
                        UIManager:close(dialog)
                        self:full_sync("download")
                    end,
                },
            },
            {
                {
                    text = _("上传本地覆盖云端"),
                    callback = function()
                        UIManager:close(dialog)
                        self:full_sync("upload")
                    end,
                },
            },
            {
                {
                    text = _("取消"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function KindleAnki:run_sync()
    Trace.mark("sync.open-collection")
    local collection = self:open_collection()
    if not collection then
        -- No local database yet: the first sync is a full download.
        return self:full_sync("download")
    end

    local ok, result = xpcall(function()
        local Runner = require("sync.runner")
        local runner = Runner.new{
            collection = collection,
            client = self:build_client(),
            paths = self.paths,
            progress = function() end,
        }
        local done = self:busy(_("正在同步…"))
        local outcome = runner:sync()
        done()
        return outcome
    end, debug.traceback)

    if not ok then
        Log.err("sync failed:", result)
        show_message(_("同步失败：") .. tostring(result))
        return
    end

    if result.status == "normal" then
        show_message(_("同步完成。"))
    elseif result.status == "noChanges" then
        show_message(_("已是最新，无需同步。"))
    elseif result.status == "fullRequired" then
        self:prompt_full_sync(result.message)
    else
        show_message(_("同步失败：") .. tostring(result.message))
    end
end

function KindleAnki:full_sync(direction)
    local ok, err = xpcall(function()
        local Runner = require("sync.runner")
        local Model = require("model.collection")
        assert(Paths.ensure(self.paths))
        -- Downloading does not need a local database: the runner writes the new
        -- file next to the target and renames it into place.  Opening an empty
        -- placeholder first fails ("collection has no col row") and, worse,
        -- leaves a schema-less file behind if the download is interrupted.
        local collection = self.collection
        if direction ~= "download" and not collection then
            collection = Model.open(self.paths.collection)
            self.collection = collection
        end
        if direction == "download" and collection then
            -- The old file is about to be replaced; close it so the rename on
            -- Kindle does not hit an open handle.
            pcall(collection.close, collection)
            self.collection = nil
            collection = nil
        end
        local runner = Runner.new{
            collection = collection,
            client = self:build_client(),
            paths = self.paths,
        }
        if direction == "download" then
            Trace.mark("sync.full-download.start")
            local done = self:busy(_("正在下载整库…"))
            local downloaded, download_error = runner:full_download()
            done()
            Trace.mark("sync.full-download.done")
            if not downloaded then
                error(download_error, 0)
            end
            self.collection = Model.open(self.paths.collection)
        else
            local done = self:busy(_("正在上传整库…"))
            local uploaded, upload_error = runner:full_upload()
            done()
            if not uploaded then
                error(upload_error, 0)
            end
        end
        return direction
    end, debug.traceback)

    if not ok then
        Log.err("full sync failed:", err)
        show_message(_("整库同步失败：") .. tostring(err))
        return
    end
    show_message(_("整库同步完成。"))
end

function KindleAnki:onKindleAnkiSync()
    if (self:read_setting("hkey", "") or "") == "" then
        self:prompt_login(true)
        return true
    end
    self:run_sync()
    return true
end

function KindleAnki:show_diagnostics()
    Probe.show(self.caps, KindleAnki.VERSION)
    return true
end

function KindleAnki:show_about()
    local lines = {
        string.format("%s %s", _("Kindle Anki"), KindleAnki.VERSION),
        "",
        _("目标：在 Kindle（KOReader）上复习 Anki 卡片，并与 AnkiWeb 同步。"),
        _("数据目录：") .. tostring(self.paths and self.paths.root or "n/a"),
        "",
        _("许可：AGPL-3.0-or-later"),
    }
    show_message(table.concat(lines, "\n"))
    return true
end
return KindleAnki
