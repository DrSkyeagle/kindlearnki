# 第三方组件与借鉴说明 / Third-party notices

本项目的代码为独立实现（AGPL-3.0-or-later，见 [LICENSE](LICENSE)）。以下是设计上
参考过、或运行时依赖的第三方项目。**除 Anki 的协议与调度语义外，没有把第三方
源代码复制进本仓库**；若将来引入代码，请在此登记其版权行与许可全文。

## 视觉参考（未复制代码）

- **[yizhixiaoheigou/kindle-anki](https://github.com/yizhixiaoheigou/kindle-anki) v0.2.0**
  （插件部分 AGPL-3.0-or-later，其余 MIT，Copyright (c) 2026 yizhixiaoheigou）
  — 复习页的**卡片渲染布局与视觉风格**（单栏、标题栏计数、底部单行评分）参考了
  该项目。本项目的实现（KOReader `ScrollHtmlWidget` + MuPDF、按 Anki 模板语义
  求值、CSS 消毒）与其代码无关。

## 协议与调度的事实依据（阅读参考，未复制代码）

- **[ankitects/anki](https://github.com/ankitects/anki)** — `rslib` 的同步协议
  （`sync/collection/*.rs`）与 v3 调度器。逐条出处见
  `kindlearnki.koplugin/doc/SYNC-SPEC.md`、`doc/SCHED-SPEC.md`。Anki 本身以
  AGPL-3.0 发布。
- **[ankidroid/Anki-Android](https://github.com/ankidroid/Anki-Android)** — 协议 v11
  与调度行为的交叉验证对象（GPL-3.0）。

## 运行时依赖（未随仓库分发）

- **[KOReader](https://github.com/koreader/koreader)**（AGPL-3.0）— 插件宿主；
  使用其 UI 组件、MuPDF 绑定、LuaSocket/LuaSec、zstd 与 sqlite 绑定。
- 仓库内的 `tools/lj/` 只包含用于**离线测试**的 LuaJIT 可执行文件与
  `sqlite3`/`zstd` 动态库（LuaJIT 为 MIT；SQLite 为公有领域；zstd 为 BSD-3-Clause）。
  它们不参与插件运行，可以删除。
