# 同步协议规范（AnkiWeb v11）

> 状态：**0.2.0 已实现增量同步 + 整库双向**（§1 传输层、行编解码、usn 记账、sanityCheck2）；媒体同步（msync）未接入。
> 规则：**代码不得超出本文件**。任何实现细节先在这里写成一条，并标注出处，再写 Lua。
> 出处三类：`[源码]` = 本机 `anki-26.09.3/rslib/src/...` 的行号；`[实测]` = 旧项目
> `koanki/ankiweb.koplugin/doc/协议笔记.md`（对真实 AnkiWeb 抓包）；`[待验]` = 尚未复核。

---

## 1. 传输层

### 1.1 端点

全部为 `POST`，路径前缀 `sync/`，方法名与 `SyncMethod` 枚举一一对应 `[源码] rslib/src/sync/collection/protocol.rs:34-68`：

| 方法 | 路径 | 请求体 | 响应体 | 说明 |
|---|---|---|---|---|
| `hostKey` | `sync/hostKey` | 账号/密码 | `{key: ...}` | 登录换 hkey |
| `meta` | `sync/meta` | `{v, cv}` | `{mod, scm, usn, ts, msg, cont, hostNum, empty, media_usn}` | 同步前握手 |
| `start` | `sync/start` | `{minUsn, lnewer, graves?}` | `{graves}` | 开始增量 |
| `applyGraves` | `sync/applyGraves` | `{chunk: {cards, notes, decks}}` | `{}` | 删除墓碑 |
| `applyChanges` | `sync/applyChanges` | `{changes: {models, decks, tags}}` | `{models, decks, tags}` | 结构变更 |
| `chunk` | `sync/chunk` | `{}` | `{done, cards?, notes?, revlog?}` | 拉取（循环） |
| `applyChunk` | `sync/applyChunk` | `{chunk: ...}` | `{}` | 推送 |
| `sanityCheck2` | `sync/sanityCheck2` | `{client: [...]}` | `{status, c, s}` | 服务器校验计数 |
| `finish` | `sync/finish` | `{}` | 裸数字（新 mod） | 结束增量 |
| `abort` | `sync/abort` | `{}` | `{}` | 中止 |
| `upload` | `sync/upload` | zstd(裸 sqlite) | `"OK"` | 整库上传 |
| `download` | `sync/download` | `{}` | zstd(裸 sqlite) | 整库下载 |

媒体同步走另一套前缀 `msync/`（`begin` / `mediaChanges` / `downloadFiles` / `mediaSanity`），见 §5（待写）。

### 1.2 请求头

```
anki-sync: {"v":11,"k":"<hkey>","c":"<客户端版本，可为空串>","s":"<6 位随机会话键>"}
content-type: application/octet-stream
```

- 头名 `anki-sync` `[源码] rslib/src/sync/request/header_and_stream.rs:129`。
- 四个键**必须都在**：`AnkiWeb` 对缺键回裸 400 `[实测]`。
- `v` 是同步版本，当前 11；服务端 `ensure_supported()` `[源码] header_and_stream.rs:39`。
- `c` 的格式不参与校验（可以为空串），但**键必须在** `[实测]`。
- `s` 是会话键；服务端把它回显在同一头里 `[源码] header_and_stream.rs:60-75`（`session_key`）。
- 媒体请求额外带 `media_client_version` 字段 `[源码] header_and_stream.rs:60-75`，见 §5。

### 1.3 压缩

- 请求体与响应体都是 **zstd 帧**，不是 protobuf `[实测]`；protobuf 只存在于客户端本地的 backend IPC。
- 服务端解压入口 `decode_zstd_body_for_server`，并强制 `MAXIMUM_SYNC_PAYLOAD_BYTES_UNCOMPRESSED` 上限 `[源码] header_and_stream.rs:57-88`。
- 解压用流式（`ZSTD_decompressStream`），不要用 `ZSTD_getFrameContentSize`：线上帧头 `FCS=0 / Single_Segment=0`，没有原始长度 `[实测]`。
- 响应头 `anki-original-size` 只作提示，**不得**按它预分配缓冲区（旧插件曾因此被伪造成 60 MB 而 OOM）`[实测]`。
- 整库 `upload` 也是 zstd 包裹的裸 sqlite 字节，不是裸字节 `[实测]`。

### 1.4 状态码与重定向

- `GET /sync/meta` → 405：同步端点只接受 POST `[实测]`。
- `AnkiWeb` 对 `sync/meta` 可回 **308**，`Location` 指向按用户分配的主机（如 `sync10.ankiweb.net`）；客户端必须跟随，并在后续请求里沿用它 `[实测]`。
- 缺头/坏头 → 裸 400（无 JSON）`[实测]`。

### 1.5 版本与身份字符串

- 客户端在 `cv` 里自报身份，格式必须形如 `anki,<版本>,<平台>`（至少两个逗号，且以 `anki,` 开头）`[实测]`。
- 本项目发送：`anki,<VERSION> (kindlearnki),koreader`。
- `c` 头同理但要短：`<VERSION>,kindlearnki,koreader` `[待验]`（旧插件发 `0.1.0,ankiweb.koplugin,koreader` 可用）。

---

## 2. 消息形状（待写）

- `meta` / `start` / `applyChanges` 的字段与 `serde(default)` 行为
- `chunk` 的 250 行上限与 `applyChunk` 的批量
- `graves` 的三种类型

**出处**：`rslib/src/sync/collection/{meta,start,changes,chunks,graves}.rs`，逐字段抄。

## 3. usn 记账（待写）

本地待同步行（`usn = -1`）的挑选、发送前改写、`sanityCheck2` 前 8 张表不得残留 `-1`、`finish` 后的 `ls/usn/mod` 更新。

**出处**：`rslib/src/sync/collection/{normal,finish,sanity}.rs`；`[实测]` 协议笔记 §4。

### 3.1 实测补充（0.2.19）

- `Store.pending()` 必须返回**具名**行表：`protocol.card_row()` 按 `row.id`/`row.nid`
  取值，把 `select` 的位置数组直接喂进去会编码出 id=0 的零行，而服务器照样回 200
  `[实测：0.2.18 及以前]`。
- 推送请求失败时必须把行改回 `usn = -1`（`Store.restore_pending`），否则这些复习
  永远到不了服务器。
- `cards.data` / `notes.data` 在 schema 里没有声明类型，但 rslib 按 `Vec<u8>` 读；
  写入必须走 `sqlite3_bind_blob`。
- 每次同步前从数据库重新读 `col.mod/usn`（`Store.refresh_timestamps`），内存里的
  值在复习之后就是旧的。

## 4. 整库同步（待写）

`before_upload`（清 graves、`usn` 归零、`scm=now`）、流式压缩/解压、原子换入与 `.bak` 回滚、`ver != 18` 的拒绝。

**出处**：`rslib/src/sync/collection/{upload,download,mod}.rs`。

### 4.1 实测补充（0.2.19）

- `before_upload` 要补 `ls = scm`、`col.usn = usn + 1`，并刷新内存里的
  `scm/mod/usn/ls`；上传成功后必须 `Collection:reload()`，否则下一次同步会拿旧
  `scm` 跟自己的上传比，又要求整库同步。
- 换入新文件前先关闭连接，换入后删除旧的 `-wal`/`-shm`（否则旧 WAL 会套在新库上）。
- 结构不一致（`meta.scm`）或 `applyChanges` 带回牌组/笔记类型/标签改动时，**不**
  让用户二选一，也不中止同步：快照 `usn = -1` 的行 → 整库下载 → 把快照行
  `apply_chunk` 回去 → `col.mod` 推进 → 重新走一次普通增量，把它们推上去。
  依据：rslib 的 `process_unchunked_changes` 本来就是在普通同步里应用这些改动；
  我们不解析 schema 11 的牌组/笔记类型结构，所以用"接管云端库 + 回放本地复习"
  达到同样效果，且不会丢复习 `[源码] normal.rs:121-143, changes.rs:225-243`。
- 一次同步里出现第二次结构变化就放弃并报错，避免死循环。


## 5. 媒体（`msync/*`）（待写）

> **0.3.x 范围：不实现。** 媒体靠 USB 手动拷贝到 `koreader/kindlearnki/media/`
> （`使用说明.md` §4.2）；渲染侧只负责把 `<img src>` 解析到该目录（0.3.1）。
> Kindle 是只读复习设备，永远不会在设备上产生新媒体，所以将来若接入，也只需要单向下载
> （`begin` → `mediaChanges` → `downloadFiles`），不需要 `uploadChanges`。

信封多一层 `{"data":…,"err":""}`、`downloadFiles` 回裸 zip、任一文件缺失整批 409、单批 >2.5 MB 截断。

## 6. 错误映射（待写）

断网、超时、时间偏差 >300 s、hkey 失效、结构不一致、校验不一致 → 中文可行动文案。

