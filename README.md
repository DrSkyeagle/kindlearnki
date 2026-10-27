# Kindle Anki（kindleanki.koplugin）

在越狱的 Kindle（KOReader ≥ v2026.07.1）上复习 Anki 卡片，并与 AnkiWeb 双向同步。

这是一个**重写**，不是旧 `ankiweb.koplugin` 的增量修补：

- 只做四件事：**牌组 → 复习 → 同步 → 设置**；
- 调度对齐 Anki 的 **v3 核心语义**（三队列、每日限额、学习/重学步、ease、leech、兄弟卡 bury、凌晨跨天）；
- 卡片按 **HTML + CSS + 图片** 渲染；音频 / JS / 数学公式 / 输入答案明确降级；
- 同步按 AnkiWeb **协议 v11** 重写，先写规范（`doc/SYNC-SPEC.md`）再写代码；
- 数据放在独立目录 `koreader/kindleanki/`，旧 `koreader/data/ankiweb/` 不动，随时可回退。

## 状态

**M0（骨架）已完成**：插件可加载、双菜单入口可注册、能力探测全绿、离线测试 13/13、
对拍工具可用。复习/调度/同步按 `doc/` 里的里程碑推进（下一步 M1）。

## 验证

```powershell
# L1：离线单元测试（无需 KOReader）
.\tools\lj\luajit.exe kindleanki.koplugin\tests\run.lua

# L2：在真实 KOReader 树里加载插件并建菜单（WSL，KO-test 发行版）
wsl -d KO-test -e bash -lc 'cd /root/koanki-test/squashfs-root/usr/lib/koreader && \
  xvfb-run -a env SDL_VIDEODRIVER=x11 PLUGIN_DIR=/mnt/d/ankindle/kindleanki.koplugin \
  ./luajit /mnt/d/ankindle/harness/load_plugin.lua'

# L1.5：对拍金标准（真 Anki 后端）
& C:\deepseekharness\koanki\.venv\Scripts\python.exe tools\diff\dump_queue.py `
    --collection <collection.anki2> --limit 5 --out out\queue.json
```

## 目录

```
kindleanki.koplugin/   插件本体（唯一源码）
  core/                版本、日志、路径、能力探测
  ui/                  KOReader 界面（tokens 与四屏）
  db/ proto/ model/    schema-18 读写与数据模型
  sched/               v3 调度
  render/              模板求值、消毒、媒体引用
  sync/                v11 协议、HTTP、zstd、同步编排
  doc/                 规范与验收文档
  tests/               离线测试（Windows LuaJIT 可跑）
tools/lj/              测试用 LuaJIT + sqlite3.dll + libzstd.dll
harness/krsim/         测试用 KOReader 替身树（lua-ljsqlite3）
```

## 跑测试

```powershell
cd D:\ankindle
.\tools\lj\luajit.exe kindleanki.koplugin\tests\run.lua
```

只跑名字里包含某段的用例：`... run.lua capabilities`

## 许可

AGPL-3.0-or-later。调度语义与同步协议实现参考 Anki 的 rslib 与 AnkiDroid，
但**不链接**其二进制；协议事实来源见 `doc/SYNC-SPEC.md` 的出处标注。
