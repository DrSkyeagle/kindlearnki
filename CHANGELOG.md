# Changelog

## [0.1.0-dev] — 2026-10-28

M0（骨架）完成。此版本**不能复习**，只证明宿主与质量闸门可用。

### Added

- KOReader 插件入口：`_meta.lua` / `main.lua`，tools 与 main 两个标签页各一个入口，
  两个 Dispatcher 动作（`KindleAnkiStudy` / `KindleAnkiSync`）。
- `core/capabilities.lua`：加载时探测 `html / sqlite / zstd / ca` 四项能力，
  一次日志输出 `kindleanki: koreader=… html=ok sqlite=ok zstd=ok ca=yes`；
  缺项时明确列出，不静默。
- `core/paths.lua`：独立命名空间 `koreader/kindleanki/`，旧 `ankiweb/` 不受影响。
- `core/log.lua`：统一日志出口，可注入 sink，凭据有 `Log.secret()` 专用出口。
- L1 离线测试 13 条（Windows LuaJIT，无需 KOReader）。
- `harness/load_plugin.lua`：在真实 KOReader 树里加载插件、建菜单、跑能力探测。
- `tools/diff/dump_queue.py`：用真 Anki 后端导出 v3 队列与四档评分，作为调度对拍金标准。
- `doc/SYNC-SPEC.md` §1（传输层）与 `doc/SCHED-SPEC.md` §1（时间与跨天）。

### Fixed (during development)

- `for _, entry in ipairs(...)` 的 `_` 遮蔽 gettext 的 `_`，会让
  `registerToMainMenu` 抛错、菜单永不出现；改为 `entry_index` 并加注释。
- 顶层 `require("ui/widget/infomessage")` 会在无 Screen 的宿主上炸
  （`ui/font` → `CanvasContext:isKindle`）；改为按需加载。
