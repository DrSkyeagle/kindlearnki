# Kindlearnki — 在 Kindle 上复习 Anki 并与 AnkiWeb 双向同步

> 一个 KOReader 插件：在**越狱的 Kindle**（KOReader ≥ v2026.07.1）上复习 Anki 牌组，
> 与 AnkiWeb 增量同步，手机端（AnkiDroid / Anki 桌面版）的进度照常互通。

<p align="center">
  <img src="docs/screenshots/study-front.png" width="30%" alt="复习：卡片正面">
  <img src="docs/screenshots/study-answer.png" width="30%" alt="复习：卡片背面与评分">
  <img src="docs/screenshots/decklist.png" width="30%" alt="牌组列表">
</p>

**English TL;DR** — A KOReader plugin for jailbroken Kindles: study your Anki decks
on e-ink and sync both ways with AnkiWeb (protocol v11, schema 18). The scheduler
mirrors Anki's v3 core (queues, daily limits, learning steps, leeches, sibling
bury, 4 a.m. rollover); cards render as HTML/CSS with images through MuPDF.
Tested on a Kindle Voyage and inside the Kindle 5.13.6 firmware emulator.
Licensed AGPL-3.0-or-later.

---

## 它做什么

只做四件事，每件都按 Anki 的真实语义实现，而不是"看起来像"：

| 功能 | 说明 |
|---|---|
| **牌组** | 树形牌组、今日新/学/复计数、全部牌组一起复习 |
| **复习** | 三队列（new/learning/review）、每日限额、学习步与重学步、ease/间隔、leech、兄弟卡 bury、凌晨 4 点跨天；四键评分带实时间隔 |
| **同步** | AnkiWeb 协议 v11 + schema 18：增量同步、整库双向、`sanityCheck2` 校验 |
| **登录** | 邮箱 + 密码换 hkey；密码不落盘，本地只存 hkey |

### 同步的关键行为

- 手机改过牌组/笔记类型时，Kindle **不会**弹"需要整库同步"：插件自动接管云端那份，
  把本机还没推上去的复习按修改时间合并回去，然后继续把复习推上去。
- 一次同步里连续出现两次结构变化才放弃（防死循环）。
- 推送失败不会把复习标记成"已发送"，下次同步会补推。

## 安装

1. Kindle 已越狱，并装好 **KOReader ≥ v2026.07.1**（先能正常打开一本书）。
2. 从 Releases 下载 `kindlearnki-koplugin-<版本>.tgz`。
3. 解压到 KOReader 的插件目录：

   ```bash
   # 在电脑上解压后拷贝，或在 Kindle 的 kterm 里执行：
   cd /mnt/us/koreader/plugins
   tar -xzf /mnt/us/kindlearnki-koplugin-0.3.0.tgz
   ```

   结果应为 `/mnt/us/koreader/plugins/kindlearnki.koplugin/`（目录名必须带 `.koplugin`）。
4. 重启 KOReader（插件在启动时加载）。

入口：主菜单 → **工具**（扳手）标签页最底部 → **Kindlearnki**。

## 使用

1. **登录**：工具 → Kindlearnki → 立即同步 → 输入 AnkiWeb 邮箱与密码。
2. **同步一次**：首次同步会创建本地库（约 5 MB 的整库下载）。
3. **复习**：开始复习 → 选牌组（或"全部牌组一起复习"）。
4. 评分键：`重来 / 困难 / 记住 / 太简单`；Voyage 上可用侧键翻页、`×` 退出。

## 从 kindleanki 升级

0.3.0 起项目改名为 **kindlearnki**（避免与同类项目混淆）。首次启动会自动把旧的
`koreader/kindleanki/collection.anki2` 与 `koreader/settings/kindleanki.lua`
复制到新路径，**进度和登录都保留**，旧文件原样留着可回退。

本项目与 `yizhixiaoheigou/kindle-anki` 的插件互不冲突（插件目录名不同、数据目录不同），
可以同时安装，但入口和评分界面各自独立。

## 数据位置

| 内容 | 路径 |
|---|---|
| 本地库 | `koreader/kindlearnki/collection.anki2` |
| 设置 / hkey | `koreader/settings/kindlearnki.lua`（hkey 为明文，注意设备共享） |
| 整库备份 | 同步时自动生成 `collection.anki2.bak` |
| 媒体缓存 | `koreader/kindlearnki/media/` |

想撤销设备密钥：AnkiWeb 网页版 → 设置 → 已登录设备。

## 已知限制

- 只做复习与同步：**不**提供浏览、编辑、统计、导入（.apkg 请在手机/桌面端导入后同步过来）。
- 媒体（图片/音频）需要同步时下载，未下载的卡片显示占位符。
- 只在 **Kindle Voyage**（1072×1448，armv7）与 5.13.6 固件模拟器上验收过；其它机型
  按以下前提应可用：KOReader 能跑、`libsqlite3`/`libzstd` 可用（启动日志会打印能力探测）。
- AnkiWeb 是唯一同步后端（不支持自建 sync server）。

## 开发与测试

无需 KOReader 即可跑离线测试（仓库自带 Windows 用 LuaJIT；Linux 用系统 luajit）：

```bash
./tools/lj/luajit.exe kindlearnki.koplugin/tests/run.lua        # 234 例，0 失败
# 可选：接真实集合，覆盖"真卡片真模板"的集成用例
KINDLEARNKI_TEST_COLLECTION=/path/to/collection.anki2 \
  ./tools/lj/luajit.exe kindlearnki.koplugin/tests/run.lua
```

真机/固件级验证（会渲染截图，需要 KOReader 树）：

```bash
bash harness/run_sync_e2e.sh          # 对 mock AnkiWeb 跑完整同步（正常/结构变更/失败注入）
bash harness/emu/emu_up.sh            # 启动 Kindle 固件模拟器并装插件
bash harness/emu/emu_nav.sh decklist  # 驱动界面（httpinspector）
bash harness/emu/emu_sync_mock.sh     # 固件内跑完整同步
```

规范与设计记录在 `kindlearnki.koplugin/doc/`：`使用说明.md`、`验收.md`、
`SYNC-SPEC.md`（同步协议逐条出处）、`SCHED-SPEC.md`（调度语义）、`模拟器.md`（固件模拟器）。

## 致谢

- [yizhixiaoheigou/kindle-anki](https://github.com/yizhixiaoheigou/kindle-anki)（v0.2.0）：
  复习页的**卡片渲染布局与视觉风格**参考了该项目。本项目为独立实现，未包含其源代码。
- [Anki](https://github.com/ankitects/anki) 的 `rslib` 与
  [AnkiDroid](https://github.com/ankidroid/Anki-Android)：
  调度语义与同步协议的事实依据（逐条标注在 `doc/SYNC-SPEC.md`、`doc/SCHED-SPEC.md`）。
- [KOReader](https://github.com/koreader/koreader)：插件运行时、HTML 渲染（MuPDF）、
  LuaSocket/LuaSec 与 zstd。

非官方项目：与 Anki、AnkiWeb、Amazon Kindle 均无隶属关系。

## 许可

[AGPL-3.0-or-later](LICENSE)。第三方组件与借鉴说明见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
