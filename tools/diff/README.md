# 对拍工具（L1.5）

`dump_queue.py` 用**真 Anki 后端**（`anki` Python 包 / rslib）打开集合，导出 v3 队列与四档评分结果。
Lua 调度器在同一个夹具上重放，比较：

- **队列顺序**：必须逐条一致；
- **间隔**：允许 fuzz 区间（0.95–1.05），不要求逐值相同；
- **计数 / elapsed_days / 学习步秒数**：见 `kindleanki.koplugin/tests/test_sched_golden.lua`。

## 依赖

需要一个带 `anki` 包的 Python。本机现成的是：

```
C:\\deepseekharness\\koanki\\.venv\\Scripts\\python.exe
```

## 重新生成金标准（夹具变化后必须做）

夹具是**用户真实数据**，会被同步/复习流程改写；重下或复习过之后旧金标准立即过期。
先把它复制成一份稳定快照（仓库 `out/` 已被 gitignore，不进版本库），再对快照 dump：

```powershell
# 1) 冻结当前夹具（2026-10-31 使用的快照，sha256 19fa056b7513d26a23b8f8d39c24b2297382850c2df5027a8ef837c5e737ff4e）
copy C:\\deepseekharness\\koanki\\bench\\work\\live\\collection.anki2 out\\fixture-snapshot-20261031-0053.anki2

# 2) 复习卡金标准：取一个只有复习卡、且当前有到期卡的牌组
& C:\\deepseekharness\\koanki\\.venv\\Scripts\\python.exe tools\\diff\\dump_queue.py `
    --collection out\\fixture-snapshot-20261031-0053.anki2 `
    --deck 1784512477702 --limit 6 --format lua --out out\\golden.lua

# 3) 新卡金标准：好文章::知乎好文章 子树，12 条队列
& C:\\deepseekharness\\koanki\\.venv\\Scripts\\python.exe tools\\diff\\dump_queue.py `
    --collection out\\fixture-snapshot-20261031-0053.anki2 `
    --deck 1782139166456 --limit 12 --format lua --out out\\golden_new.lua
```

为什么 `golden.lua` 要显式选牌组：集合的**活动牌组**是 `1787138061852`（Anki更新），
它的 6 张复习卡在 2026-10-31 00:45 被 review harness 复习过（due 推到 406+），
所以“活动牌组”当前有 0 张到期卡；`1784512477702`（乳腺肿瘤 UpToDate）有 32 张到期复习卡且
没有新卡/学习中卡，最适合验证复习 fuzz 区间。

金标准里记录了快照身份（`crt` / `mod`）与 `today`：夹具被重下/改写后，
`test_sched_golden.lua` 会检测到并打印 `SKIP ... regenerate ...`（跳过数在输出里），而不是把
夹具变化误报成调度器错误。

## 写入器的 BLOB / TEXT 兼容修复

集合里每个声明为 BLOB 的 protobuf 列（`decks.common`、`notetypes.config`、`deck_config.config`、
`config.val` ……）rslib 都按 `Vec<u8>` 读。旧版写入器把 Lua string 当 TEXT 绑定，
Anki 会以 `DBError { info: "InvalidType", kind: Other }` 拒绝**整个集合**（字节内容其实没坏）。

`dump_queue.py` 在**临时副本**上自动把 “声明 BLOB 但存成 TEXT” 的列转回 BLOB，
并逐条打印：

```
FIXTURE-SANITIZED decks.common TEXT->BLOB (1 row(s))
```

源文件永远不改；`--no-sanitize` 可关闭（在旧夹具上会复现 `InvalidType`，用于确认修复确有必要）。
`pragma integrity_check` 的 `row not in PRIMARY KEY order for tags` 只作为
`FIXTURE-NOTE ... (informational)` 打印，不影响调度 dump。

写入侧的正确做法见 `kindleanki.koplugin/db/conn.lua` 的 `Conn.blob()`；回归测试在
`kindleanki.koplugin/tests/test_blob_types.lua`（`bump_studied writes decks.common as a BLOB`）。

## 旧用法（JSON 队列，保留）

```powershell
& C:\\deepseekharness\\koanki\\.venv\\Scripts\\python.exe `
    tools\\diff\\dump_queue.py `
    --collection C:\\deepseekharness\\koanki\\bench\\work\\live\\collection.anki2 `
    --limit 20 --out out\\queue.json
```

脚本会把集合（含 `-wal`/`-shm`）复制到临时目录再打开，**不会锁住或改动**源文件。

## 为什么不是"跑一遍 AnkiDroid"

AnkiDroid 2.16.5 的 Java 层只是壳；调度全在 rslib 里。桌面 `anki` 包链接的是同一套
rslib，因此在 PC 上对拍等价于对拍 AnkiDroid 的后端，且能拿到结构化输出。
