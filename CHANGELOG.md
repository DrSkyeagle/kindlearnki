# Changelog

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
