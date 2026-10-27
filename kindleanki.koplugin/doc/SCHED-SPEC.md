# 调度规范（Anki v3 核心）

> 状态：**§1 已写**（时间与跨天）；§2 起待写。
> 规则：代码不得超出本文件；每条规则标注 `anki-26.09.3/rslib/src/...` 的出处。
> 目标：与 AnkiDroid 2.16.5 / 桌面 Anki 共用同一个集合时，**队列顺序一致、间隔落在允许区间内**。
> 明确不追求逐值一致：v3 的间隔 fuzz 是随机的（见 §4 待写）。

---

## 1. 时间与跨天

### 1.1 两个时间输入

- `col.crt`：集合创建时间（UNIX 秒）。
- `config` 表里的 `CreationOffset` / `LocalOffset`：创建时与当前的 **minutes west of UTC**
  （例如 UTC+10 记为 `-600`）`[源码] rslib/src/config/mod.rs:50-52,162-183`。
- 跨天小时 `rollover`：集合 `config` 表里的 `rollover`（本集合 = 4）`[实测]`。

### 1.2 days_elapsed 的算法

`[源码] rslib/src/scheduler/timing.rs:22-76`：

```
created_dt = crt 在 creation_offset 下的本地时间
now_dt     = now 在当前 offset 下的本地时间
rollover_today = now_dt 的 当天 00:00 + rollover 小时
rollover_passed = (rollover_today <= now_dt)

days = num_days_from_ce(now_dt) - num_days_from_ce(created_dt)
if not rollover_passed then days = days - 1 end
days = max(days, 0)

next_day_at = rollover_passed ? rollover_today + 1 天 : rollover_today
```

要点：

1. **不是** `floor((now - crt) / 86400)`（那是 v1 的行为，`[源码] timing.rs:114-124`）。
2. 用**本地日历日**相减，再按"今天是否已过 rollover"修正；跨时区/夏令时因此不会漂。
3. `num_days_from_ce` 需要自己实现：由 `os.date("*t", ts)` 取 y/m/d，再算 Gregorian 日序号（Lua 无内置）。
4. `creationOffset` 缺失时是 v2 的 legacy 处理路径 `[源码] timing.rs:165`；本集合有该键，按 1.2 走。

### 1.3 复习卡的 due 语义

- 复习卡 `due` 存的是 **`days_elapsed` 口径的"天序号"**，不是时间戳。
- 学习卡 `due` 是 **UNIX 秒**（到点即出队）。
- 新卡 `due` 是 **位置**（用于排序，不是时间）。
- 因此三者在同一列里靠 `type`/`queue` 区分，**不能混算**（旧插件曾把两者混排，导致"先发明天的卡"）。

> 这一条的字段级细节（`queue` 枚举、`type` 枚举、`left` 的语义）补在 §2。

---

## 2. 状态模型（待写）

`type` / `queue` / `due` / `left` / `ivl` / `factor` 的组合，以及 suspend/bury 的 `queue` 取值。
**出处**：`rslib/src/card/mod.rs`、`proto/anki/cards.proto`。

## 3. 队列构建（待写）

顺序：interday learning → review → new（受 `dayLearnFirst`、`newSpread`、deck config 的
`new_card_gather_priority` / `review_card_order` / `review_mix` 影响）。
**出处**：`rslib/src/scheduler/queue/builder/{mod,gathering,sorting,intersperser}.rs`。

## 4. 作答（待写）

四条评分路径的状态迁移与间隔公式、ease 增减、lapse 新间隔、`fuzz 0.95–1.05`（随机，逐值不可比）。
**出处**：`rslib/src/scheduler/answering/`、`states/`。

## 5. 限额（待写）

`new_per_day` / `reviews_per_day`、今日已用量的 revlog 口径、子牌组聚合。
**出处**：`rslib/src/decks/limits.rs`、`scheduler/queue/builder/mod.rs`。

## 6. leech 与 bury（待写）

阈值与动作（suspend / tag-only）、兄弟卡 bury 的触发点。
**出处**：`rslib/src/scheduler/bury_and_suspend.rs`、`deckconfig` 的 `leech_action`。

## 7. 验收方法（待写）

与 `.venv` 的 anki 26.09.3 对拍：同一夹具 + 同一作答序列 → 队列顺序逐条一致、间隔在区间内。
