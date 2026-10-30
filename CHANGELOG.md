# Changelog

## [0.2.9] — 2026-10-30

### Fixed

- **整库同步 HTTP 303**：设备日志显示 `POST https://sync.ankiweb.net/sync/download`
  → `code=303`。AnkiWeb 用 **303 See Other** 把账号分流到 `sync{N}.ankiweb.net`，
  而客户端只处理了 308，于是把 303 当成错误。现在 301/302/303/307/308 统一按
  “向 Location 重发同一请求”处理（与 rslib 行为一致），并把分配到的 host 记在
  `client.endpoint` 上；重定向次数上限仍是 `Client.MAX_REDIRECTS`。

### Added

- `tests/test_client.lua`：303 到主机根、303 到完整路由、303 缺 Location 三种用例。

## [0.2.8] — 2026-10-30

首次整库同步在设备上走不通，USB 日志（`/f/koreader/crash.log`）给出三处连锁问题：

### Fixed

1. **数据目录不存在**：`ljsqlite3[cantopen] unable to open database file`。插件从未创建
   `<koreader>/kindleanki/`，SQLite 不会替你创建父目录。新增 `Paths.mkdir_p` /
   `Paths.ensure`（优先用 KOReader 自带 lfs，桌面回退到 shell），在 `init()`、
   `open_collection()`、`full_sync()` 之前调用。
2. **下载前预先打开了空库**：整库下载分支先 `Model.open()` 建了个空 SQLite 文件，
   而空库没有 `col` 行，`load_meta()` 直接报 `collection has no col row`。现在下载
   不再预开本地库：`Runner.new` 允许 `collection = nil`，下载完成后再打开；若目标
   文件存在则先关闭旧连接再替换，避免 Kindle 上重命名失败。
3. **校验下载库时缺少排序规则**：`pragma quick_check` 会检查带 `COLLATE unicase`
   的索引，未注册该 collation 时报 `no such collation sequence: unicase`，导致好库
   被判定“校验失败”。`verify_collection` 现在先 `Collation.install(conn)`。

### Added

- `tests/test_paths.lua`：目录创建、幂等、嵌套父目录。
- `tests/test_runner.lua`：**本地库不存在时的整库下载**（正是设备失败路径），
  包括下载后能正常打开并数到卡片。
- `harness/smoke_main.lua`：新增“全新目录下建库”一步。

## [0.2.7] — 2026-10-30

### Fixed

- **`main.lua` 把 `UIManager` 当全局用**：文件里 13 处 `UIManager:…` 却从未
  `require`，而 KOReader 不提供 `_G.UIManager`。设备日志（USB 读取）实证：
  ```
  main.lua:345: attempt to index global 'UIManager' (a nil value)
    in function 'busy'      ← network_selftest → busy → InfoMessage
    in function 'network_selftest'
  ```
  KOReader 抛错退出、KUAL 把框架拉起，看起来就是“重启”。已在文件头补
  `local UIManager = require("ui/uimanager")`。

### Added

- **`tests/test_globals.lua`**：静态检查每个模块用到的 KOReader 全局
  （UIManager/InfoMessage/ButtonDialog/InputDialog/Font/Screen/Device/…）是否
  有对应 require 或 local 声明；并自带“确实能抓到缺失 require”的自测。
- **`harness/smoke_main.lua`**：按 KOReader 的方式加载并实例化插件，然后**真的调用
  `network_selftest`**（InfoMessage + UIManager + 真实 TLS）。静态检查看不到
  “方法运行到一半才炸”的错误，这个 harness 能看到。
- `harness/load_plugin.lua`：不再写死子菜单数量，改为断言关键条目都在。

## [0.2.6] — 2026-10-30

### Changed

- 登录与网络自检在发起 TLS 前执行两次 `collectgarbage("collect")`，并把
  `login: memory before request` / `after request` 写进 crash.log —— Kindle 512 MB
  下，键盘 + 卡片文档 + 握手同时存在的内存峰值是可测的了。
- `harness/network_check.lua`：在真实 KOReader 运行时里跑同一套 `socket/ssl`
  与 CA，再发一次真实 POST。本机结果：握手成功，AnkiWeb 返回 400（请求到达服务器）。
- **崩溃面包屑**（`core/trace.lua`）：在 `login.submit` / `login.request.start` /
  `login.request.done` / `selftest.*` 各写一行 `last-stage.txt` 并立即 close。
  原生崩溃会丢掉日志缓冲，但这个文件一定落盘；下次启动时插件会把上次的最后阶段
  以 `previous run stopped at: …` 写进 crash.log。

## [0.2.5] — 2026-10-30

### Fixed

- **`sync/transport.lua` 语法错误**（上一版引入）：`apply_timeouts` 里留了一句裸表达式
  `socket.core`，Lua 不允许裸表达式作语句，导致模块无法加载 —— 设备上表现为
  “网络诊断不可用：'=' expected near 'end'”，登录也走不到 TLS。已删除。

### Added

- **`tests/test_syntax.lua`**：编译插件目录下每一个 `.lua`（`loadfile`，不执行），
  任何语法错误都会让 L1 套件变红。
- **`tools/pack_plugin.py` 语法闸门**：打包前用自带 LuaJIT 编译所有待入包文件，
  有错直接拒绝打包。上一版能带着语法错误发出去，就是因为缺这道闸。

## [0.2.4] — 2026-10-30

### Added

- **网络诊断**菜单项：分步检查 `require socket` → TCP 连接 → `require ssl` →
  TLS 握手（含 CA 校验），每步写 crash.log 并弹中文结果。它不需要账号，能在
  “登录”之前单独验证原生 TLS 栈。

### Changed

- 登录提交改为**延后 0.3 秒**执行（`UIManager:scheduleIn`），让对话框/键盘收尾
  完成后再开始阻塞式 TLS；整段用 `xpcall` + traceback 包裹。
- 登录与 HTTP 全链路加**分步日志**：`login: submit` → `login: host_key begin`
  → `http: request` → `http: connecting` → `http: returned …` → `login: host_key
  returned`。原生崩溃无法被 pcall 捕获，crash.log 的最后一行就是最后完成的阶段。
- `sync/transport.lua` 明确区分 LuaSocket 的三种返回形态（成功 / nil,err /
  抛异常），并设置 `socketutil` 的连接超时。

## [0.2.3] — 2026-10-30

### Fixed

- **Kindle 上点登录输入框不弹软键盘、随即系统软重启**：登录页不再自绘
  `InputText`（它拿不到 KOReader 对话框的焦点/键盘路径），改为 KOReader 原生
  `InputDialog` 两步流程：邮箱 → 密码。键盘由 `InputDialog:onShowKeyboard()`
  打开，和 Wi-Fi 密码框走同一条路。
- 密码步骤用 `text_type = "password"`（v2026.07 的 InputDialog 会透传给
  InputText，`inputdialog.lua:381`），仍保持掩码。
- `tests/test_module_paths.lua` 相应改为锁住三件事：必须用 InputDialog、不得再
  require `InputText`/`centercontainer`、密码步骤必须带 `text_type` 且弹键盘。
- `harness/ui_shot.lua` 增加两步登录的真实渲染与提交验证（含密码掩码断言）。

## [0.2.2] — 2026-10-30

### Fixed

- **真机「登录界面不可用」**：`ui/login.lua` 引用了 `ui/widget/centercontainer`，
  该模块在 KOReader v2026.07 已移到 `ui/widget/container/centercontainer`；
  require 失败被 `prompt_login` 的兜底文案吞成一句提示。改到新路径。
- **登录对话框透明**：FrameContainer 默认无底色，叠在复习页上时卡片文字透上来；
  给对话框与两个输入框补白底（输入框加 1px 边框）。
- 新增 `harness/require_check.lua`：在真实 KOReader 树里逐个 require 32 个模块
  （含只在有 Screen/CanvasContext 时才能加载的 UI 模块），本次即由它定位到上述路径。
- 新增 `tests/test_module_paths.lua` 锁住这两点（旧路径不得回归、对话框必须有底）。

## [0.2.1] — 2026-10-28

### Changed

- **PagePress 改为翻卡片正文**（`PgFwd` 下一页 / `PgBack` 上一页），不再绑定
  「显示答案 / 记住」。原因：真实卡片经常有好几屏，e-ink 上不支持滚动，按键必须优先
  服务长卡片；显示答案与评分改由触摸完成（通栏黑条 / 四列）。
- 新增 `previous_body_page()`；翻页到顶/到底时按键不动作（不会误翻面）。
- 正文仍可点：多页时点一下翻下一页，最后一页再点显示答案（正面）。

## [0.2.0] — 2026-10-28

功能闭环：复习、调度、渲染、同步。真机验收待做。

### Added

- **数据层**：schema-18 只读模型（`col`/`config`/`decks`/`deck_config`/`notetypes`/
  `fields`/`templates`/`cards`/`notes`/`revlog`/`graves`）、`unicase` 排序规则、
  语句缓存、逐卡事务。
- **调度器**：v3 new/learning/review/relearning 四态 × 四评分、学习/重学步、
  ease 增减、leech、兄弟卡 bury、凌晨 4 点跨天、按 `decks.common` 的每日限额、
  fuzz 区间计算。
- **对拍**：`tools/diff/dump_queue.py` 用真 Anki 后端生成金标准；新卡步长逐值一致、
  复习间隔落在 fuzz 区间、ease 精确一致、`elapsed_days` 口径修正。
- **渲染**：模板求值、条件段、Cloze（问题面隐藏/答案面揭示）、FrontSide、特殊字段、
  `text:`/`hint:` 过滤器，白名单 HTML/CSS 消毒。
- **界面**：静纸牌组页、复习页（PagePress 翻面/评分、退出热区、长卡分页）、
  登录页（密码掩码）；tokens 单点可调。
- **同步**：JSON、流式 zstd、v11 协议行编解码、可注入 transport 的客户端、
  增量同步编排（meta→start→applyChanges→拉→推→sanityCheck2→finish）、
  整库下载原子换入 + `.bak`、整库上传流式压缩、中文错误映射。
- **工具**：`pack_plugin.py`（zip + 逐字节校验）、`deploy_to_kindle.ps1`、
  `harness/load_plugin.lua`、`harness/ui_shot.lua`（L2 截图）。

### Fixed（开发期抓到）

- `for _, entry in ipairs(...)` 的 `_` 遮蔽 gettext，菜单静默消失。
- 顶层 require `ui/widget/infomessage` 在无 Screen 宿主上崩溃。
- protobuf packed repeated float 未解码，导致学习步为空、新卡直接毕业。
- `elapsed_days` 误用 `today - due`（少算一个 interval）。
- revlog id 同毫秒冲突（改为探测空闲 id）。
- 整库下载路径重复解压（client 已解压）。
- 牌组总数误用 deck 1 子树（应为所有顶层牌组之和）。

## [0.1.0-dev] — 2026-10-28

M0 骨架：插件加载、能力探测、13 条离线测试、协议/调度规范初稿、对拍工具。
