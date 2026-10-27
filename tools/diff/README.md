# 对拍工具（L1.5）

`dump_queue.py` 用**真 Anki 后端**打开集合，导出 v3 队列与四档评分结果。
Lua 调度器在同一个夹具上重放，比较：

- **队列顺序**：必须逐条一致；
- **间隔**：允许 fuzz 区间（0.95–1.05），不要求逐值相同。

## 依赖

需要一个带 `anki` 包的 Python。本机现成的是：

```
C:\deepseekharness\koanki\.venv\Scripts\python.exe
```

## 用法

```powershell
& C:\deepseekharness\koanki\.venv\Scripts\python.exe `
    tools\diff\dump_queue.py `
    --collection C:\deepseekharness\koanki\bench\work\live\collection.anki2 `
    --limit 20 --out out\queue.json
```

脚本会把集合（含 `-wal`/`-shm`）复制到临时目录再打开，**不会锁住或改动**源文件。

## 为什么不是"跑一遍 AnkiDroid"

AnkiDroid 2.16.5 的 Java 层只是壳；调度全在 rslib 里。桌面 `anki` 包链接的是同一套
rslib，因此在 PC 上对拍等价于对拍 AnkiDroid 的后端，且能拿到结构化输出。
