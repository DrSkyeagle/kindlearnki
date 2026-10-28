# Kindle Anki（kindleanki.koplugin）

在越狱的 Kindle Voyage（KOReader ≥ v2026.07.1）上复习 Anki 卡片，并与 AnkiWeb 双向同步。

这是一个**重写**，不是旧 `ankiweb.koplugin` 的增量修补：

- 只做四件事：**牌组 → 复习 → 同步 → 设置**；
- 调度对齐 Anki **v3 核心语义**（三队列、每日限额、学习/重学步、ease、leech、兄弟卡 bury、凌晨 4 点跨天）；
- 卡片按 **HTML + CSS + 图片** 渲染（MuPDF），模板语义按 Anki 源码实现；
- 同步按 AnkiWeb **协议 v11** 实现：增量同步 + 整库双向 + sanityCheck2；
- 数据放在独立目录 `koreader/kindleanki/`，旧 `koreader/data/ankiweb/` 不动，随时可回退。

## 状态

**0.2.1**：功能闭环，L1/L1.5/L2 全绿；**真机验收尚未执行**（清单见
`kindleanki.koplugin/doc/验收.md`）。开发者用法见 `doc/使用说明.md`。

| 层 | 状态 |
|---|---|
| 数据层（schema 18 读写、`unicase`、deck/notetype/deck_config protobuf） | 完成 |
| 调度（v3 核心，与真 Anki 后端对拍） | 完成 |
| 渲染（模板/条件/cloze/FrontSide/特殊字段 + 消毒） | 完成 |
| 界面（牌组页 / 复习页 / 登录；静纸 tokens） | 完成，L2 截图验证 |
| 同步（登录、增量、整库双向、错误映射） | 完成，离线编排验证 |
| 媒体（图片下载缓存） | **未接入**（缺图显示占位符） |

## 验证

```powershell
# L1：离线单元/集成测试（Windows LuaJIT；真实库用例由环境变量开启）
$env:KINDLEANKI_TEST_COLLECTION='C:\deepseekharness\koanki\bench\work\live\collection.anki2'
.\tools\lj\luajit.exe kindleanki.koplugin\tests\run.lua

# L1.5：与真 Anki 后端对拍（生成金标准，再跑 golden 用例）
& C:\deepseekharness\koanki\.venv\Scripts\python.exe tools\diff\dump_queue.py `
    --collection <collection.anki2> --limit 6 --format lua --out out\golden.lua

# L2：在真实 KOReader 树里渲染三个屏并截图（WSL + Xvfb）
#   命令见 kindleanki.koplugin/doc/验收.md

# 打包 / 校验
python tools\pack_plugin.py
python tools\pack_plugin.py --check
```

## 目录

```
kindleanki.koplugin/   插件本体（唯一源码）
  core/                版本、日志、路径、能力探测
  db/ proto/ model/    schema-18 读写、protobuf、数据模型
  sched/               v3 调度（timing/config/states/queue/answer）
  render/              模板求值 + HTML/CSS 消毒
  sync/                协议、HTTP、zstd、JSON、存储合并、编排
  study/               会话、牌组列表、控制器
  ui/                  tokens、牌组页、复习页、登录
  doc/                 使用说明、验收、SCHED/SYNC 规范
  tests/               离线测试（Windows LuaJIT 可跑）
tools/                 LuaJIT 测试运行时、对拍脚本、打包与部署脚本
harness/               KOReader 替身树、加载检查、L2 截图驱动
out/                   构建与截图产物（git 忽略）
```

## 许可

AGPL-3.0-or-later。调度语义与同步协议实现参考 Anki 的 rslib 与 AnkiDroid，
但**不链接**其二进制；协议事实来源见 `doc/SYNC-SPEC.md` 的出处标注。


