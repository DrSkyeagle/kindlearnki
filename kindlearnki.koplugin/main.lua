--[[--
Kindlearnki — KOReader plugin entry point.

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
local Prefs = require("core.prefs")
local Trace = require("core.trace")
local Capabilities = require("core.capabilities")

local Kindlearnki = WidgetContainer:extend{
    name = "kindlearnki",
    is_doc_only = false,
}

Kindlearnki.VERSION = Version.VERSION

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
Kindlearnki.MENU_ENTRIES = {
    { key = "kindlearnki", hint = "tools" },
    { key = "kindlearnki_main", hint = "main" },
}

Kindlearnki.DISPATCHER_ACTIONS = {
    {
        name = "kindlearnki_study",
        event = "KindlearnkiStudy",
        title = _("Kindlearnki：开始复习"),
    },
    {
        name = "kindlearnki_sync",
        event = "KindlearnkiSync",
        title = _("Kindlearnki：立即同步"),
    },
}

--==========================================================================
-- Lifecycle
--==========================================================================

function Kindlearnki:init()
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

    -- Module names inside a KOReader plugin are global (`require("core.paths")`
    -- resolves to whichever plugin directory comes first on package.path), so a
    -- leftover 0.2.x `kindleanki.koplugin` would shadow this plugin's modules and
    -- fail with a message that points nowhere.  Say what is actually wrong.
    if type(Paths.migrate_legacy) ~= "function" or Log.PREFIX ~= "kindlearnki" then
        Log.err("another plugin is providing core.paths/core.log",
            "(an old kindleanki.koplugin is probably still installed at",
            "koreader/plugins/kindleanki.koplugin -- delete it and restart KOReader)")
        return
    end

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
        -- The plugin was called kindleanki before 0.3.0; copy that install's
        -- collection and AnkiWeb key across so an upgrade keeps its progress.
        local migrated = Paths.migrate_legacy(self.paths)
        if migrated and (migrated.collection or migrated.settings) then
            Log.info(string.format(
                "migrated kindleanki data (collection=%s settings=%s) to %s",
                tostring(migrated.collection == true),
                tostring(migrated.settings == true), self.paths.root))
        end
        self.caps = Capabilities.probe{
            ca_path = self.paths.ca_bundle,
        }
        Log.info(self.caps.summary)
        -- Screens read their numbers from here; attach before anything paints.
        Prefs.attach(self:settings())
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
        -- The Voyage rocker only reports while deviced has the fsr keypad
        -- switched on, and KOReader does that itself only in its no-framework
        -- launch mode.  Switching it on here too makes the same bindings work
        -- when the stock framework is still running (no-op off Kindle).
        pcall(function()
            require("core.pagepress").ensure()
        end)
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
function Kindlearnki:register_menu()
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
function Kindlearnki:register_dispatcher_actions()
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
    for action_index, action in ipairs(Kindlearnki.DISPATCHER_ACTIONS) do
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

function Kindlearnki:onDispatcherRegisterActions()
    self:register_dispatcher_actions()
end

--==========================================================================
-- Menu
--==========================================================================

function Kindlearnki:build_submenu()
    return {
        {
            text = _("开始复习"),
            callback = function()
                self:onKindlearnkiStudy()
            end,
        },
        {
            text = _("立即同步"),
            callback = function()
                self:onKindlearnkiSync()
            end,
        },
        {
            text = _("复习页左右边距"),
            callback = function()
                self:prompt_study_margin()
            end,
        },
        {
            text = _("显示缩放"),
            callback = function()
                self:prompt_card_zoom()
            end,
        },
        {
            text = _("图片缩放"),
            callback = function()
                self:prompt_image_zoom()
            end,
        },
        {
            text = _("删除卡片库"),
            callback = function()
                self:prompt_delete_library()
            end,
        },
        {
            text = _("注销本地账户"),
            callback = function()
                self:prompt_logout_local()
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

function Kindlearnki:addToMainMenu(menu_items)
    for entry_index, entry in ipairs(Kindlearnki.MENU_ENTRIES) do
        menu_items[entry.key] = {
            text = _("Kindlearnki"),
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
function Kindlearnki:open_collection()
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

function Kindlearnki:close_collection()
    if self.collection then
        pcall(self.collection.close, self.collection)
        self.collection = nil
    end
end

--==========================================================================
-- Actions
--==========================================================================

function Kindlearnki:onKindlearnkiStudy()
    local collection, err = self:open_collection()
    if not collection then
        show_message(tostring(err))
        return true
    end

    local ok, result = xpcall(function()
        local Controller = require("study.controller")
        return Controller.show_decks(collection, {
            -- Where `<img src="...">` is resolved from.  Without it every card
            -- image renders as MuPDF's `[image]` placeholder even when the file
            -- is sitting in the media folder.
            media_dir = self:media_dir(),
            -- The deck screen has its own 同步 button; without this callback it
            -- was a dead zone that swallowed the tap.  Route it through the
            -- hkey-guarded entry point: calling run_sync() directly POSTs to
            -- AnkiWeb without a host key, the server answers 400, and the user
            -- is told to reinstall the plugin when they simply are not logged in.
            on_sync = function()
                self:onKindlearnkiSync()
            end,
        })
    end, debug.traceback)
    if not ok then
        Log.err("study screen failed:", result)
        show_message(_("打开复习界面失败，详情见 crash.log。"))
    end
    return true
end

--- The media line appended to every sync result.
--
-- One fixed sentence, not a path interpolated from the `media_dir` setting: the
-- folder is a constant of the plugin, and a path that changes with a setting
-- reads like something the user has to configure before it works.  It is
-- deliberately *not* repeated during study -- a user who keeps pictures off the
-- device is making a choice, and the cards already show MuPDF's `[image]`.
function Kindlearnki:media_hint()
    return _("媒体文件可自行复制到koreader/kindlearnki/media中。")
end

--- A sync result message with the media line appended.
function Kindlearnki:sync_message(text)
    return tostring(text) .. self:media_hint()
end

--==========================================================================
-- Sync
--==========================================================================

function Kindlearnki:settings()
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

function Kindlearnki:read_setting(key, default)
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

function Kindlearnki:save_setting(key, value)
    local settings = self:settings()
    if not settings then
        return
    end
    settings:saveSetting(key, value)
    settings:flush()
end

--- Where card media (images) are read from.
--
-- Defaults to the plugin's own `koreader/kindlearnki/media/`, which is created
-- on every start and is reachable over USB.  The `media_dir` setting lets a
-- user point at a folder they already copy `collection.media` into; it is
-- never created or written by us.
-- @treturn string|nil
function Kindlearnki:media_dir()
    if not self.paths then
        return nil
    end
    return Paths.media_source(self.paths, self:read_setting("media_dir", ""))
end

function Kindlearnki:build_client()
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
function Kindlearnki:busy(message)
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

function Kindlearnki:prompt_login(then_sync)
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

--- Confirm, then delete the local card library.
--
-- Separate from 注销本地账户 on purpose: a failed sync is the common reason for
-- wanting a clean slate, and that must not cost the user their login.
function Kindlearnki:prompt_delete_library()
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = _("删除本地卡片库？\n\n登录状态保留，可用于强制云端覆写。"),
        buttons = {
            {
                {
                    text = _("删除"),
                    callback = function()
                        UIManager:close(dialog)
                        self:delete_library()
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
    return true
end

--- Drop every local copy of the library, keeping the login.
function Kindlearnki:delete_library()
    -- The handle has to go first: removing a file SQLite still has open either
    -- fails outright or leaves the WAL behind, and the next download would then
    -- be compared against a stale journal.
    self:close_collection()
    local result = Paths.remove_library(self.paths)
    if #result.failed > 0 then
        local first = result.failed[1]
        Log.err("delete library failed:", first.path, tostring(first.error))
        show_message(_("删除失败：") .. tostring(first.error) .. "\n" .. first.path)
        return true
    end
    if #result.removed == 0 then
        show_message(_("本地没有卡片库，无需删除。"))
        return true
    end
    show_message(_("本地卡片库已删除。下次同步会从云端重新下载。"))
    return true
end

--- Ask for a number and store it in the preferences.
--
-- A SpinWidget rather than a list of presets: the values are percentages and
-- design units, and any fixed set of presets would be one step off the
-- reader's taste.  The range and the default come from `core/prefs.lua`, so
-- the dialog and the screens can never disagree.
local function prompt_number(key, title, info, step, hold_step)
    local ok_widget, SpinWidget = pcall(require, "ui/widget/spinwidget")
    if not ok_widget then
        Log.err("cannot load spinwidget:", SpinWidget)
        show_message(_("当前 KOReader 版本不支持数值设置。"))
        return
    end
    local limits = Prefs.LIMITS[key]
    UIManager:show(SpinWidget:new{
        title_text = title,
        info_text = info,
        value = Prefs.get(key),
        value_min = limits.min,
        value_max = limits.max,
        value_step = step or 1,
        value_hold_step = hold_step or (step and step * 10 or 10),
        default_value = Prefs.DEFAULTS[key],
        callback = function(spin)
            local saved = Prefs.set(key, spin.value)
            show_message(string.format("%s：%d", title, saved))
        end,
    })
end

--- Ask for the study screen's horizontal margin.
function Kindlearnki:prompt_study_margin()
    prompt_number("study_margin", _("复习页左右边距"),
        _("与牌组页同一单位：10 即牌组页的边距，0 是贴边。"), 1, 5)
end

--- Ask for the card font zoom ("显示缩放" in AnkiDroid).
function Kindlearnki:prompt_card_zoom()
    prompt_number("card_zoom", _("显示缩放"),
        _("卡片文字大小，百分比。100 是默认大小，调大看小字更清楚。"), 5, 25)
end

--- Ask for the image zoom ("图片缩放" in AnkiDroid).
function Kindlearnki:prompt_image_zoom()
    prompt_number("image_zoom", _("图片缩放"),
        _("图片大小，相对图片原始尺寸的百分比。100 是原始大小，超过屏幕宽度时会自动缩到一屏。"), 5, 25)
end

--- Confirm, then forget the account: the key *and* the library.
--
-- The library has to go with the key.  Keeping it would mean the next sync
-- pushes the previous account's cards and review history into whichever
-- account logs in next.
function Kindlearnki:prompt_logout_local()
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = _("注销本地账户？\n\n将删除本机保存的登录信息，并同时删除本地卡片库，"
            .. "避免旧账户的数据混入新账户。下次同步需要重新登录。"),
        buttons = {
            {
                {
                    text = _("注销"),
                    callback = function()
                        UIManager:close(dialog)
                        self:logout_local()
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
    return true
end

--- Drop the key and the library together.
function Kindlearnki:logout_local()
    self:close_collection()
    local result = Paths.remove_library(self.paths)
    local settings = self:settings()
    if settings then
        settings:delSetting("hkey")
        settings:flush()
    end
    if #result.failed > 0 then
        local first = result.failed[1]
        Log.err("logout: library delete failed:", first.path, tostring(first.error))
        show_message(_("已注销登录，但本地卡片库没删干净：")
            .. tostring(first.error) .. "\n" .. first.path)
        return true
    end
    show_message(_("已注销本地账户，本地卡片库已删除。下次同步请重新登录。"))
    return true
end

--- Ask which side wins when the schema differs.
function Kindlearnki:prompt_full_sync(reason)
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

function Kindlearnki:run_sync()
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
        show_message(self:sync_message(_("同步完成。")))
    elseif result.status == "noChanges" then
        show_message(self:sync_message(_("已是最新，无需同步。")))
    elseif result.status == "fullRequired" then
        self:prompt_full_sync(result.message)
    else
        show_message(_("同步失败：") .. tostring(result.message))
    end
end

function Kindlearnki:full_sync(direction)
    local ok, err = xpcall(function()
        local Runner = require("sync.runner")
        local Model = require("model.collection")
        assert(Paths.ensure(self.paths))
        -- Downloading does not need a local database: the runner writes the new
        -- file next to the target and renames it into place.  Opening an empty
        -- placeholder first fails ("collection has no col row") and, worse,
        -- leaves a schema-less file behind if the download is interrupted.
        --
        -- An existing collection is handed to the runner *without* being thrown
        -- away: the runner closes it for the rename and reloads it in place, so
        -- the deck list / study session keep a live object.  Replacing it with a
        -- new one (the old behaviour) left those screens holding a closed
        -- collection and the next tap died on `self.conn` being nil.
        local collection = self.collection
        if direction ~= "download" and not collection then
            collection = Model.open(self.paths.collection)
            self.collection = collection
        end
        local client = self:build_client()
        if direction == "download" then
            -- AnkiWeb assigns the account to sync{N}; discovering it needs one
            -- /sync/meta call, which the download path would otherwise skip.
            local host_ok, host_err = client:resolve_host()
            if not host_ok then
                error(host_err, 0)
            end
        end
        local runner = Runner.new{
            collection = collection,
            client = client,
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
            -- The runner reloads an existing collection in place; only the very
            -- first download needs a fresh object.
            if not self.collection then
                self.collection = Model.open(self.paths.collection)
            end
        else
            local done = self:busy(_("正在上传整库…"))
            local uploaded, upload_error = runner:full_upload()
            done()
            if not uploaded then
                error(upload_error, 0)
            end
            -- before_upload rewrote scm/usn/ls in the file that was just sent;
            -- the in-memory object must follow, or the next sync would compare
            -- a stale schema against our own upload and ask for another full
            -- sync (the loop the user reported).
            if self.collection then
                pcall(self.collection.reload, self.collection)
            end
        end
        return direction
    end, debug.traceback)

    if not ok then
        Log.err("full sync failed:", err)
        show_message(_("整库同步失败：") .. tostring(err))
        return
    end
    show_message(self:sync_message(_("整库同步完成。")))
end

function Kindlearnki:onKindlearnkiSync()
    if (self:read_setting("hkey", "") or "") == "" then
        self:prompt_login(true)
        return true
    end
    self:run_sync()
    return true
end

function Kindlearnki:show_about()
    local lines = {
        string.format("%s %s", _("Kindlearnki"), Kindlearnki.VERSION),
        "",
        _("目标：在 Kindle（KOReader）上复习 Anki 卡片，并与 AnkiWeb 同步。"),
        _("数据目录：") .. tostring(self.paths and self.paths.root or "n/a"),
        "",
        _("许可：AGPL-3.0-or-later"),
    }
    show_message(table.concat(lines, "\n"))
    return true
end
return Kindlearnki
