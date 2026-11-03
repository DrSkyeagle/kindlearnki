# Changelog

## [0.3.7] — 2026-11-03

### Added

- 菜单新增 **显示缩放**（50–200%，默认 100）：卡片正文字号按百分比放大缩小，
  对应 AnkiDroid 的「显示缩放」。只影响卡片文字，标题栏和评分键不动。
- 菜单新增 **图片缩放**（50–200%，默认 100）：卡片里的图片按**原始尺寸**的百分比
  缩放，对应 AnkiDroid 的「图片缩放」。100% 与以前的显示完全一致；
  放大到超过正文宽度时 MuPDF 会自动缩到一屏，不会把图裁掉。

### Notes

- MuPDF 不认 CSS `img { zoom: ... }`（AnkiDroid 用的就是它），给 `<img>` 加
  `width`/`style` 属性还会直接把渲染进程打崩。所以图片缩放走
  「`<div class="ka-zoom-N"><img ...></div>` + `.ka-zoom-N img { width: Npx }`」，
  N 由图片文件的原始像素宽乘 MuPDF 的 0.75 页面比例算出（实测 600 px 的图
  显示成 450 px，1200 px 的显示成 900 px）。支持 PNG/JPEG/GIF/WebP/BMP 文件头。
- 读不到尺寸的图**不缓存失败**：`collection.media` 通常是先看卡、后用 USB 拷进去的，
  记住那次失败会让图一直不缩放，直到重启 KOReader。

## [0.3.6] — 2026-11-03

### Added

- 菜单新增 **复习页左右边距**（Kindlearnki → 复习页左右边距），0–40 个设计单位，
  默认 10（就是牌组页的边距）。改完立即生效并写盘，下次打开复习页就用新值。

### Fixed

- **复习页右边比左边宽一倍**：`ScrollHtmlWidget` 按
  `width - scroll_bar_width - text_scroll_span` 排正文，但控件本身仍是 `width`，
  多出来的 `text_scroll_span`（8 个单位 = 15 px）全变成右侧空白。
  现在传 0，左右边距相等（只剩滚动条那 2 个单位）。

## [0.3.5] — 2026-11-03

### Changed

- 复习页的左右边距改成和牌组页**同一个数值**（`Tokens.space.margin`，10 个设计单位）；
  以前是写死的 34，卡片内容比牌组列表窄一大截，两屏左右边不齐。
  卡片正文不再自带 `0.2em` 的左右内边距（上下留白不变），所以正文第一列和第二列
  与牌组页的牌组名落在同一条竖线上。

## [0.3.4] — 2026-11-02

### Fixed

- **0.3.3 的 PagePress 修复在真机上没生效**：真日志是
  `WARN kindlearnki: page buttons: could not open a lipc handle`。
  原因：0.3.3 用 `lipc.init("com.lab126.kaf")` 开句柄，而这正是 stock 框架自己的
  LIPC client id —— 框架在跑时它已经被占用，插件拿不到句柄（模拟器里 harness 停掉了
  `lab126_gui`，id 空着，所以一直是绿的；KOReader 自己也只在 `STOP_FRAMEWORK=yes` 时才用这个 id，
  其余场合都用 `com.github.koreader.*`）。
  现在按 KOReader 的做法先开插件自己的 id `com.github.koreader.kindlearnki`，
  失败才回退 `com.lab126.kaf`（给 no-framework 模式留后路）。
- **再兜一层**：两个 id 都开不出来时，退回 `lipc-get-prop` / `lipc-set-prop` 命令行工具
  （同一根 LIPC 总线，不需要 client id），成功时日志写
  `page buttons: enabled deviced keypad via lipc-set-prop (0/1/1 -> 1/1/1)`。
  两条路都不通才 `WARN page buttons: could not reach com.lab126.deviced`。
- 测试：`tests/test_pagepress.lua` 从 9 例加到 12 例，钉住「先用自己的 id」、
  「KAF 只作兜底」、「无句柄时走命令行」、「命令行也失败要报错」；离线套件 262 passed。

## [0.3.3] — 2026-11-02

### Fixed

- **实体翻页键在「框架还在跑」的启动方式下完全没反应**（PagePress 石沉大海）。
  Kindle 的驱动只在 `com.lab126.deviced` 的 `fsrkeypadEnable` 为 1 时，才把
  `/dev/input/event2`（`fsr_keypad`，键码 104 / 109）的事件送进用户空间；KOReader 只在
  `STOP_FRAMEWORK=yes`（no-framework / 用 KUAL 停了框架）时才打开这个开关
  （`frontend/device/kindle/device.lua` 的 `KindleVoyage:init` 拿 `frameworkStopped()` 的 lipc 句柄，
  普通启动时拿到的是 `nil`）。于是开关一直是 0，插件绑上的 `PgFwd` / `PgBack` 永远收不到按键。
  新增 `core/pagepress.lua`：启动时（`main.lua`）、牌组页与复习页打开时各调一次
  `PagePress.ensure()`，用 lipc（`com.lab126.kaf`）读
  `fsrkeypadEnable` / `fsrkeypadPrevEnable` / `fsrkeypadNextEnable`，把不是 1 的置 1，
  并写一行 `page buttons: enabled deviced keypad (0/1/1 -> 1/1/1)`；已经打开就什么都不做；
  没有 fsr keypad 的机型（Oasis 等）不告警、直接跳过；非 Kindle 机器不碰 lipc。
- 去掉 `Device:hasKeys()` 门禁：`hasKeys` 只说明设备有实体键，不说明按键会送到我们这里。
  现在按 `Device.input.group` 里有没有 `PgFwd` / `PgBack` 决定是否绑定。

### Tests

- 新增 `tests/test_pagepress.lua`（8 例：`0/0/0 -> 1/1/1`、已开时零写入、`lipc.init` 返回 nil、
  `set` 抛错、无 fsr keypad、非 Kindle、缺 `liblipclua`、`available()` 只认 Voyage）；
  `tests/test_keybindings.lua` 增加「两个界面都会替运行中的框架打开开关」。
  离线套件 248 → **259 例，0 失败**。

### Verified

- 固件模拟器（Kindle Voyage 5.13.6 + KOReader v2026.07.1，框架在跑、`STOP_FRAMEWORK` 未设，
  即用户遇到的那种启动方式）：插件加载前 `lipc-get-prop com.lab126.deviced fsrkeypadEnable` = 0；
  加载后日志出现 `page buttons: enabled deviced keypad (0/1/1 -> 1/1/1)`，属性读到 1；
  把属性强行置回 0，deviced 十秒内不自愈，打开牌组页（`DeckView:init`）后属性回到 1；
  复习页照常打开。真机（Kindle Voyage）待验：这点只能靠手指按一下 PagePress 确认。

## [0.3.2] — 2026-11-01

### Added

- 菜单新增 **删除卡片库**：删掉本地 `collection.anki2` 及其 `-wal`/`-shm`/`.bak`，
  保留登录状态；用于卸载前清干净，或同步失败时强制下次从云端整库覆写。二次确认。
- 菜单新增 **注销本地账户**：删掉本机 hkey **并同时删除本地卡片库**——只删钥匙不删库的话，
  换号后首次同步会把旧账户的卡片和复习记录合并进新账户。二次确认。

### Changed

- 同步成功的消息统一为「同步完成。媒体文件可自行复制到koreader/kindlearnki/media中。」
  （三个成功分支都带；路径写死，不再跟随 `media_dir` 设置）。
- 菜单去掉 **诊断** 和 **网络诊断** 两项，连带删除 `ui/probe.lua` 与 `network_selftest()`。
  启动时的能力自检保留（只写 `crash.log`，不占菜单）。

### Fixed

- 卡片图片现在真的能显示了：复习页从来没有把媒体目录交给 MuPDF
  （`ScrollHtmlWidget` 的 `html_resource_directory` 恒为 `nil`），所以即使图片文件就在
  设备上，每张图也会被渲染成字面的 `[image]`——那是 MuPDF 的缺图占位符，不是"不支持图片"。
  现在 `study/controller.lua` 把 `resource_dir` 交给渲染层，`main.lua` 用
  `Kindlearnki:media_dir()` 提供路径（默认 `koreader/kindlearnki/media/`）。
- **牌组页的「新/学/复」拆分不再把可见行相加**：父牌组本来就算过子牌组，嵌套牌组会被
  重复计数（真实库上那一行是 707，而大数字和页脚都是 447）。现在直接用 `DeckList.build`
  算好的全库合计（新增 `DeckList.display_counts`），`新+学+复` 恒等于那个大数字。
- `sync/protocol.lua` 的 `VERSION` 改为读 `core/version.lua`，不再手抄第二份——发版时漏改
  会把旧版本号发给 AnkiWeb（这次升级正好踩中，测试先报的错）。

### Docs

- `kindlearnki.koplugin/doc/使用说明.md` 新增 **§4.2 图片与媒体（手动放入）**：Kindle 上的
  媒体目录路径（设备内 `/mnt/us/koreader/kindlearnki/media/`，连电脑
  `Kindle/koreader/kindlearnki/media/`）、电脑端 `collection.media` 的三平台路径、复制步骤、
  成功判据（卡上出现 `[image]` = 还缺文件）、可选的 `media_dir` 设置、以及背景图不显示的说明。
- 新增 **§4.3 清理与换号**：两个新菜单项各自做什么、会删什么、不会删什么。
- README 增加"图片：手动把媒体文件放进去"一节，并改掉"媒体需要同步时下载"的错误说法。

### Tests

- 新增 `tests/test_controller_face.lua`（face 交出 `resource_dir`、不再报告缺图）、
  `test_decklist` 的三条口径用例（拆分等于总数、嵌套不重复计数、以数据层为准）、
  `test_paths` 的三条删库用例（连带 `-wal`/`-shm`/`.bak`、保留设置、空库是 no-op）与
  `test_ui_guards` 里的一条接线守卫；离线套件 234 → **248 例，0 失败**。
- 新增 `harness/media_shot.lua`（L2）：同一张卡拍两遍——接上媒体目录出真图，
  不接出 MuPDF 的 `[image]`。两张不同才算接线生效（实测 162 KB vs 40 KB）。

### Scope

- 明确不做，且不打算做：**媒体联网同步**（`msync/*`）、音频/视频渲染。
  定位理由：Kindle 是只读复习终端，做卡与媒体管理属于桌面/手机端的职责；媒体总量常在
  百 MB～GB 级，Kindle 的弱 WiFi、激进休眠与 e-ink 进度反馈都不适合这种同步，而其收益
  仅是省一次 USB 拷贝；实现侧要额外承担分块上传、断点续传、失败重试、增量校验与冲突合并，
  复杂度与出错面超过复习链路本身。媒体走 USB 一次性放入 `koreader/kindlearnki/media/`。

## [0.3.0] — 2026-10-31

对外发布版本，项目改名为 **kindlearnki**（此前提到的路径与名称按新名显示）。

### Changed

- 插件目录、日志前缀、数据目录、设置文件、Dispatcher 动作与组件名统一改为
  `kindlearnki`：`koreader/plugins/kindlearnki.koplugin/`、
  `koreader/kindlearnki/`、`koreader/settings/kindlearnki.lua`、
  `KindlearnkiStudy` / `KindlearnkiSync`。
- **升级不丢进度**：首次启动会把旧的 `koreader/kindleanki/collection.anki2`
  （连同 WAL/SHM）和 `settings/kindleanki.lua` 复制到新路径，旧文件保留可回退。
  日志里会出现 `migrated kindleanki data ...`。

### Docs / repo

- README 重写为发布版：安装、使用、同步行为、数据位置、已知限制、开发与测试、致谢。
- `LICENSE` 增加项目版权头；新增 `THIRD_PARTY_NOTICES.md`（视觉参考与协议出处）、
  `CONTRIBUTING.md`、GitHub Actions（Windows 上跑离线测试 + 打包）。
- 清掉误提交的杂物文件。

## 模拟器 A 端到端同步（2026-10-31，arm 固件 + 真 KOReader）

`harness/emu/emu_sync_mock.sh`：把 `harness/mock_ankiweb.py` 用 `ssh -R` 挂到
模拟器的 loopback（该 QEMU 机器的网卡没有后端，10.0.2.2 不可达），让真实 Kindle
固件里的插件对它做一次完整同步。`structural` 模式（服务端多出牌组）下的请求序列：

```
meta, start, applyChanges        -> 响应带 1 个牌组
abort, download                  -> 接管云端库
meta, start, applyChanges, chunk -> 已是最新结构
applyChunk (244 B)               -> sync: push chunk=1 cards=6 notes=0 revlog=6
sanityCheck2, finish             -> sync: finished local_usn_now=100
```

推送的 6 张卡与 6 条 revlog 的 usn 都是服务器当时的 usn（99），与 rslib 记账一致；
模拟器里复习产生的 6 条待同步复习在接管之后被完整补推。

## [0.2.21] — 2026-10-31

### Fixed

- **复习结束回到牌组页，数字还是旧的**：会话结束后牌组行仍显示开始前的待学数
  （复习了 6 张还是写着 6），看起来像"复习没保存"。现在关闭复习页时重建牌组数据
  并 `DeckView:update()` 重绘（模拟器实测总待学 446 → 442，完成提示与关闭同时生效）。

### Tests

- `run_sync_e2e.sh` 增加 `chunkfail`：`applyChunk` 返回 500 时必须报错、复习保持
  待同步、下一次同步成功补推。三种模式（normal/structural/chunkfail）全绿。
- `emu_nav.sh sync`：在模拟器里按下牌组页的"同步"按钮，用来验未登录时的登录提示。

## [0.2.20] — 2026-10-31

真机固件（QEMU 里的 Kindle Voyage 5.13.6 + KOReader 2026.07.1）验收时发现的两处
调用点问题，以及模拟器脚本的时序修复。

### Fixed

- **牌组页的"同步"按钮绕过了登录检查**：它直接调 `run_sync()`，没登录时照样
  向 AnkiWeb POST，拿到 HTTP 400，再把"客户端版本可能过旧，请更新插件"这种误导
  信息甩给用户。现在走 `onKindlearnkiSync()`，未登录先弹登录框。
- **刷完最后一张后停在死界面**：卡片看完后画面还留在最后一张，标题继续显示
  `第 4 / 4 张`，底部还有"显示答案"和间隔为空的评分按钮，按哪个都没反应。
  现在 `controller.on_rate` 发现队列空了就关闭复习页并提示"本轮完成：共 N 张"。

### Emulator harness

- `harness/emu/env.sh` 的 `stop_framework()` 会反复停 `lab126_gui`：Kindle 的 Java
  框架在开机约 46s 才启动（我们第一次停太早），118s 起来后会把 Kindle Home 画在
  KOReader 上并吃掉 130MB，之前的截图会随机变成 Home 或被覆盖。

### Tests

- `tests/test_ui_guards.lua`：把这两处调用点钉住（同步按钮必须走
  `onKindlearnkiSync`；队列结束必须关闭复习页并给出提示）。

## [0.2.19] — 2026-10-31

同步修复：Kindle 的复习进度传不到手机，以及手机一同步 Kindle 就被要求整库同步。

### Fixed

- **上传的其实是"零行"**：`Store.pending()` 返回的是 `select` 出来的位置数组，而
  `protocol.card_row()` 按字段名（`row.id`/`row.nid`…）取值，数组上全是 nil，于是
  每张卡都编码成 id=0、mod=0 的默认行。服务器照样回 200，UI 显示"同步完成"，
  所以看起来永远成功、手机上永远没有。`pending()` 现在返回具名表（`row_to_card`
  等），并加了回归测试断言推送行的 `id/nid/mod/usn` 与本地卡片一致。
- **卡片/笔记的 `data` 存成 TEXT**：`cards.data`/`notes.data` 在 schema 里没写类型，
  但 rslib 按 `Vec<u8>` 读；绑 Lua 字符串会存成 TEXT，Anki 读这张卡就报类型错。
  写入时改走 `sqlite3_bind_blob`（`Conn.blob`），`repair_blob_storage()` 也会修这两列
  和 `tags.config`。
- **手机改结构后 Kindle 永久要求整库同步**：`applyChanges` 带回的牌组/笔记类型/标签
  变更以前直接中止同步，而中止不会"消费"掉服务器上的这些变更，于是每次同步都再次
  提示。现在改为**接管云端库 + 回放本地待同步复习**：先把待同步行快照下来，整库
  下载，按 mtime 规则把这些复习合并回去，再把 `col.mod` 推进，接着走完一次普通同步
  把它们推上去。用户的复习不丢，服务器上的结构变更被消费，下一轮就是普通增量同步。
- **整库上传后不同步内存状态**：`before_upload` 改了 `scm/usn/mod` 却没刷新对象，
  下一次同步拿旧 `scm` 跟自己的上传比 → 又要求整库同步（来回踢皮球）。现在上传后
  `Collection:reload()`，并且 `before_upload` 补齐了 rslib 的 `ls = scm`。
- **推送失败会把待同步行当成已发送**：`mark_usns` 在请求前改写 usn，网络在中途断
  掉就会永久丢复习。失败时用 `Store.restore_pending()` 把行改回 `usn = -1`。
- **`col.mod` 用的是打开文件时的旧值**：复习只改数据库，不同步对象；现在每次
  `Runner:sync()` 先 `refresh_timestamps()` 再和服务器比较，"有复习却回无事可做"
  的情况不会再出现。
- `start` 的 `lnewer` 现在按本地/服务器 `mod` 如实上报，不再恒为 false。
- 整库下载在 Windows 上会因存在性探测句柄没关掉而 `无法备份旧库`：探测句柄现在关闭
  后再 rename（真机是 Linux，不受影响，但测试和桌面模拟器会）。

### Tests

- `tests/test_runner.lua`：新增"结构不一致时接管云端库并保留本地复习""校验失败时接管
  而不是放弃""推送失败后行仍是待同步"，并把推送行内容（id/nid/mod/usn）和入站
  `data` 的 BLOB 存储类断言进去。

## [0.2.18] — 2026-10-31

复习页 UI 收三处，渲染管线（MuPDF / ScrollHtmlWidget / 会话 / 同步）一行没动。

### Changed

- **评分按钮改成一行四个**：`重来 10 分钟 | 困难 1 天 | 记住 344 天 | 太简单 890 天`。
  去掉 `·` 分隔（改空格），四格在 1072 px 面板上都能完整显示；按钮之间保留分隔线。
- **去掉正文上方的"卡片正面 / 卡片背面"两行**：正/背面从按钮就能判断，省下的两条
  文字高度全部给正文（约 100px，多 2~3 行字，长卡片少翻一页）。
- **"第 N / M 张"挪进标题栏**，跟在牌组名后面：`Default    第 1 / 4 张`。
  标题栏设 `title_multilines=false`，长牌组名由 KOReader 先缩字号再截断，
  **标题栏高度恒定**，不会因为牌组名长短让正文区上下跳。
- 空会话（没有到期卡片）标题只显示牌组名，不再出现"第 1 / 1 张"这种假计数。

### Removed

- `Tokens.card_front_text` / `Tokens.card_back_text`（不再使用）。

## [0.2.17] — 2026-10-31

分支 `kindle-ankiweb`：复习页改为参考实现
[yizhixiaoheigou/kindle-anki v0.2.0](https://github.com/yizhixiaoheigou/kindle-anki/releases/tag/v0.2.0)
的卡片版式——标题栏 + MuPDF 正文区 + 底部按钮表，正文由 MuPDF 自己排版、贴顶、
超长分页。

### Fixed

- **部分卡片正面错位 / 完全不显示**：旧版在正文区手动画框，再用
  `getUsedBBox()` 量 MuPDF 自带页边距去补偿，而补偿读的 `self.body_page_count`
  要到函数末尾才更新——上一条若是多页答案，下一条短正面就带着旧值跳过补偿，
  于是错位；残留的平移量又让内容看起来消失了。现在正文交给 `ScrollHtmlWidget`，
  不再有任何手工平移，这类 bug 从结构上消失。
- **背面正文到评分按钮之间空白过大**：正文不再垂直居中/上移，所有卡片都从正文区
  顶部同一行开始，按钮固定在底部。
- **卡片字号被模板钉死**：`strip_font_size()` 现在整条删掉绝对字号（含
  `calc(1em - 2px)`），并把注释隔开的声明也覆盖到；旧正则只删掉 `px` 前面的数字，
  留下 CSS 语法错误，MuPDF 会把后面的声明全部丢弃——这正是同一个牌组里字号忽大忽小的原因。
- **空声明导致整段样式失效**：牌组 CSS 里真的有 `color: ;`（模板作者删了颜色留下声明），
  MuPDF 遇到语法错误就停。新增 `Tokens.tidy_declarations()` 先清掉空值再交给渲染器。
- `body` 内侧留白改由样式表控制（`@page { margin: 0 }` 关掉 MuPDF 自己的 2em/3em），
  左右上下边距从此一致，不再随字号放大。

### Changed

- 卡片字号改用 `Tokens.card_font_px()`（Voyage 上 38px，约每行 24 个汉字），
  与参考实现一致；牌组名移到标题栏，进度在正文第一行（`第 N / M 张`）。
- 正面只剩一个通栏“显示答案”，退出用标题栏的 ×；背面是 2×2 评分按钮
  （重来/困难/记住/太简单 + 下次间隔）。
- `harness/study_tap.lua` 会挑一个真的有待学卡片的牌组，并连刷三张卡
  （正面 → 显示答案 → 评分 → 下一张），逐步打印 `px/pages/bbox`；同时把交给
  MuPDF 的 HTML/CSS 落到 `face-front.html` / `face.css` 供事后诊断。

### Also in this branch

- **BLOB 存储类**：`decks.common` 等列在 schema 里是 BLOB，之前用普通 Lua 字符串
  绑定会被 SQLite 存成 TEXT，Anki 端读到会报 `InvalidType`。`Conn.blob()` 改走
  `sqlite3_bind_blob`，上传前再 `repair_blob_storage()` 修一遍。
- `out/golden.lua` 与新基准集合漂移导致的两条差分测试失败：`tools/diff/dump_queue.py`
  可重新生成 golden 快照，`tests/test_sched_golden.lua` 改为按当前快照比较。

## [0.2.16] — 2026-10-31

### Fixed

- **卡片四周大片空白**：实测 MuPDF 在页面内自带约 2em 左右、3em 上下的边距
  （55px 字号下正好 110/165px），CSS reset 和内联样式都去不掉。现在先按原宽度
  排版、量出 `getUsedBBox()` 的边距，再对**同一份文档** `layoutDocument()` 加宽
  2 倍边距并平移绘制（不重新解析 HTML，避免把原生内存峰值翻倍）。内容实测宽度
  1071px ≈ 面板 1072px，左边距 0。
- 绘制顺序改为**正文先画、页眉/进度线/答案栏后画**，卡片贴顶后不会盖住顶部信息。

### Added

- `harness/study_tap.lua` 增加断言：内容宽度必须接近正文盒宽度、且发生了左移。

## [0.2.15] — 2026-10-30

### Changed

- 卡片字号从 64px 降到 **56px**（`width * 0.052`）。64px 下设备复习两张卡后就重启，
  最可能是 MuPDF 原生内存/布局峰值；先给原生侧留余量，稳定后再逐步加回去。
- 卡片渲染时把 `VmRSS` 写进日志（`card render rss=… MB px=…`），下次若仍重启，
  日志能直接说明是内存涨到顶还是别的原因。
- 正文 CSS 追加 `body,h1..h6,p,div,...{margin:0;padding:0}` 并剥离模板的
  `text-align`：MuPDF 之前仍在套用模板的居中与默认外边距（实测内容 bbox 左边距
  191px），这是“上下左右边距大得吓人”的直接来源。

## [0.2.14] — 2026-10-30

### Fixed

- **点牌组进不去（0.2.12/0.2.13 引入）**：`study/controller.lua` 里把
  `Controller.card_style()` 写成了小写 `controller.card_style()`，渲染卡片时抛
  “attempt to call a nil value”，牌组行的回调被 pcall 吞掉，表现就是点了没反应。
- 卡片外层补 `width:100%; display:block`，避免 MuPDF 把内容按文字宽度收缩后居中
  造成左边大留白。

### Added

- `harness/study_tap.lua`：模拟点击第一个牌组行 → 断言复习页真的打开并截图
  （`10-study-from-deck.png`）。这个用例在 0.2.12 就能抓到上面的错。
- `tests/test_module_paths.lua`：锁住 `Controller.card_style()` 的大小写。
- `harness/smoke_main.lua`：真实调用 `card_style()` 并检查返回的样式串。

## [0.2.13] — 2026-10-30

### Fixed

- **0.2.12 的分隔符归一化写错了字节**：源码里落成的是 0x19（Python 把 ``
  按八进制解释），而 Anki 用的是 **0x1F**，所以三级牌组依旧显示。改为
  `string.char(31)`，并把转换抽成 `Collection.printable_deck_name` 加了回归测试。

## [0.2.12] — 2026-10-30

### Fixed

- **三级牌组仍显示**：Anki 数据库里牌组名的层级分隔符是 `0x1f`，不是 `::`；
  `depth_of()` 因此全部算成 0，过滤形同虚设。`Collection:load_decks` 现在把 `0x1f`
  归一成 `::`，`DeckList.build` 也做了同样防御。
- **牌组页的“同步”按钮无反应**：`Controller.show_decks` 只在传入 `on_sync` 时才挂回调，
  而 `main` 调它时没传，点击落进空函数。已接上 `self:run_sync()`。
- **卡片偏小 / 底色干扰**：
  - 字号按屏宽 6% 计算，Voyage 上正好 **64px**（原来被模板的 `20px` 压住）；
  - `Tokens.strip_backgrounds` 去掉 `background-color` / `background-image` / `box-shadow`
    以及不含 `url()` 的 `background` 简写（含 data URI 的保留，避免把 CSS 撕坏）；
  - 卡片外层 div 加内联样式（MuPDF 对内联样式优先级最高）：白底、黑字、左对齐、无边距；
  - 正文区改为左右通栏、下沿贴到答案栏、内容**贴顶**显示，不再垂直居中留白。

### Added

- `tests/test_decklist.lua` 用 `0x1f` 构造真实存储形态；`tests/test_tokens.lua` 覆盖
  64px 目标与底色剥离。

## [0.2.11] — 2026-10-30

同步成功后的三处使用反馈：

### Fixed

- **牌组页无法翻页**：牌组行此前只有“放得下就显示、放不下就提示另有 N 个”，没有任何翻页手段。
  现在按可用高度算出每页行数并分页：`PgFwd`/`PgBack` 翻页，右下角 `2/3` 计数可点（循环）。
- **牌组只显示两级**：`DeckList.build` 增加 `max_depth`（默认 2），三级及更深的牌组不再
  单独列行；其卡片数仍计入父牌组（`Queue.counts` 本就算整棵子树）。
- **卡片字号太小**：Anki 模板几乎都写着 `.card{font-size:20px}`，会盖掉我们传入的字号。
  现在按屏幕尺寸算字号（`Tokens.body_font_px`：约 26 个汉字/行、34 行/页，钳制 24–64px；
  Voyage 上 41px），并剔除 CSS 里写死的 `px`/`pt` 字号，让 `em`/`%` 继承新基准。

### Added

- `tests/test_decklist.lua`：两级过滤、隐藏牌组计数、总数口径。
- `tests/test_tokens.lua`：字号随屏幕缩放与钳制、CSS 字号剥离（保留 `em`）。
- `harness/ui_shot.lua`：25 个牌组的分页截图（`08/09-decks-page*.png`）。

## [0.2.10] — 2026-10-30

### Fixed

- **整库同步仍然 303**：这次是“没先问主机”。用设备上的 hkey 复现实测：
  - `POST https://sync.ankiweb.net/sync/meta` → **308** `location: https://sync10.ankiweb.net/`
  - `POST https://sync.ankiweb.net/sync/download` → **303**，**无 Location**，body 就是字面量 `303`
  - 在 `sync10` 上发**完全相同**的请求 → **HTTP/2 200**，3.1 MB zstd 数据
  
  即：303 是“主机不对”的信号，而分配的主机只能从 `/sync/meta` 的 308 得知。
  整库下载分支此前直接下载、跳过 meta；现在先 `client:resolve_host()`（内部调用 meta），
  再下载。普通同步本来第一步就是 meta，因此只有首次整库下载受影响。

### Added

- `tests/test_client.lua`：`resolve_host` 的 308 跟随、下载落到分配主机、meta 失败即中止。

## [0.2.9] — 2026-10-30

### Fixed

- **整库同步 HTTP 303**：设备日志显示 `POST https://sync.ankiweb.net/sync/download`
  → `code=303`。AnkiWeb 用 **303 See Other** 把账号分流到 `sync{N}.ankiweb.net`，
  而客户端只处理了 308，于是把 303 当成错误。现在 301/302/303/307/308 统一按
  “向 Location 重发同一请求”处理（与 rslib 行为一致），并把分配到的 host 记在
  `client.endpoint` 上；重定向次数上限仍是 `Client.MAX_REDIRECTS`。

### Added

- `tests/test_client.lua`：303 到主机根、303 到完整路由、303 缺 Location 三种用例。

## [0.2.8] — 2026-10-30

首次整库同步在设备上走不通，USB 日志（`/f/koreader/crash.log`）给出三处连锁问题：

### Fixed

1. **数据目录不存在**：`ljsqlite3[cantopen] unable to open database file`。插件从未创建
   `<koreader>/kindlearnki/`，SQLite 不会替你创建父目录。新增 `Paths.mkdir_p` /
   `Paths.ensure`（优先用 KOReader 自带 lfs，桌面回退到 shell），在 `init()`、
   `open_collection()`、`full_sync()` 之前调用。
2. **下载前预先打开了空库**：整库下载分支先 `Model.open()` 建了个空 SQLite 文件，
   而空库没有 `col` 行，`load_meta()` 直接报 `collection has no col row`。现在下载
   不再预开本地库：`Runner.new` 允许 `collection = nil`，下载完成后再打开；若目标
   文件存在则先关闭旧连接再替换，避免 Kindle 上重命名失败。
3. **校验下载库时缺少排序规则**：`pragma quick_check` 会检查带 `COLLATE unicase`
   的索引，未注册该 collation 时报 `no such collation sequence: unicase`，导致好库
   被判定“校验失败”。`verify_collection` 现在先 `Collation.install(conn)`。

### Added

- `tests/test_paths.lua`：目录创建、幂等、嵌套父目录。
- `tests/test_runner.lua`：**本地库不存在时的整库下载**（正是设备失败路径），
  包括下载后能正常打开并数到卡片。
- `harness/smoke_main.lua`：新增“全新目录下建库”一步。

## [0.2.7] — 2026-10-30

### Fixed

- **`main.lua` 把 `UIManager` 当全局用**：文件里 13 处 `UIManager:…` 却从未
  `require`，而 KOReader 不提供 `_G.UIManager`。设备日志（USB 读取）实证：
  ```
  main.lua:345: attempt to index global 'UIManager' (a nil value)
    in function 'busy'      ← network_selftest → busy → InfoMessage
    in function 'network_selftest'
  ```
  KOReader 抛错退出、KUAL 把框架拉起，看起来就是“重启”。已在文件头补
  `local UIManager = require("ui/uimanager")`。

### Added

- **`tests/test_globals.lua`**：静态检查每个模块用到的 KOReader 全局
  （UIManager/InfoMessage/ButtonDialog/InputDialog/Font/Screen/Device/…）是否
  有对应 require 或 local 声明；并自带“确实能抓到缺失 require”的自测。
- **`harness/smoke_main.lua`**：按 KOReader 的方式加载并实例化插件，然后**真的调用
  `network_selftest`**（InfoMessage + UIManager + 真实 TLS）。静态检查看不到
  “方法运行到一半才炸”的错误，这个 harness 能看到。
- `harness/load_plugin.lua`：不再写死子菜单数量，改为断言关键条目都在。

## [0.2.6] — 2026-10-30

### Changed

- 登录与网络自检在发起 TLS 前执行两次 `collectgarbage("collect")`，并把
  `login: memory before request` / `after request` 写进 crash.log —— Kindle 512 MB
  下，键盘 + 卡片文档 + 握手同时存在的内存峰值是可测的了。
- `harness/network_check.lua`：在真实 KOReader 运行时里跑同一套 `socket/ssl`
  与 CA，再发一次真实 POST。本机结果：握手成功，AnkiWeb 返回 400（请求到达服务器）。
- **崩溃面包屑**（`core/trace.lua`）：在 `login.submit` / `login.request.start` /
  `login.request.done` / `selftest.*` 各写一行 `last-stage.txt` 并立即 close。
  原生崩溃会丢掉日志缓冲，但这个文件一定落盘；下次启动时插件会把上次的最后阶段
  以 `previous run stopped at: …` 写进 crash.log。

## [0.2.5] — 2026-10-30

### Fixed

- **`sync/transport.lua` 语法错误**（上一版引入）：`apply_timeouts` 里留了一句裸表达式
  `socket.core`，Lua 不允许裸表达式作语句，导致模块无法加载 —— 设备上表现为
  “网络诊断不可用：'=' expected near 'end'”，登录也走不到 TLS。已删除。

### Added

- **`tests/test_syntax.lua`**：编译插件目录下每一个 `.lua`（`loadfile`，不执行），
  任何语法错误都会让 L1 套件变红。
- **`tools/pack_plugin.py` 语法闸门**：打包前用自带 LuaJIT 编译所有待入包文件，
  有错直接拒绝打包。上一版能带着语法错误发出去，就是因为缺这道闸。

## [0.2.4] — 2026-10-30

### Added

- **网络诊断**菜单项：分步检查 `require socket` → TCP 连接 → `require ssl` →
  TLS 握手（含 CA 校验），每步写 crash.log 并弹中文结果。它不需要账号，能在
  “登录”之前单独验证原生 TLS 栈。

### Changed

- 登录提交改为**延后 0.3 秒**执行（`UIManager:scheduleIn`），让对话框/键盘收尾
  完成后再开始阻塞式 TLS；整段用 `xpcall` + traceback 包裹。
- 登录与 HTTP 全链路加**分步日志**：`login: submit` → `login: host_key begin`
  → `http: request` → `http: connecting` → `http: returned …` → `login: host_key
  returned`。原生崩溃无法被 pcall 捕获，crash.log 的最后一行就是最后完成的阶段。
- `sync/transport.lua` 明确区分 LuaSocket 的三种返回形态（成功 / nil,err /
  抛异常），并设置 `socketutil` 的连接超时。

## [0.2.3] — 2026-10-30

### Fixed

- **Kindle 上点登录输入框不弹软键盘、随即系统软重启**：登录页不再自绘
  `InputText`（它拿不到 KOReader 对话框的焦点/键盘路径），改为 KOReader 原生
  `InputDialog` 两步流程：邮箱 → 密码。键盘由 `InputDialog:onShowKeyboard()`
  打开，和 Wi-Fi 密码框走同一条路。
- 密码步骤用 `text_type = "password"`（v2026.07 的 InputDialog 会透传给
  InputText，`inputdialog.lua:381`），仍保持掩码。
- `tests/test_module_paths.lua` 相应改为锁住三件事：必须用 InputDialog、不得再
  require `InputText`/`centercontainer`、密码步骤必须带 `text_type` 且弹键盘。
- `harness/ui_shot.lua` 增加两步登录的真实渲染与提交验证（含密码掩码断言）。

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

---

## 真机同步验收（2026-10-31，AnkiWeb 实测）

Kindle Voyage（真机）在 KOReader 里执行一次同步，`crash.log` 记录的完整链路：

```
sync: sync local_mod=1793381084000 server_mod=1793381399778 usn=254/256
sync: applyChanges structural models=0 decks=2/0 tags=0
sync: adopt server collection (...): pending cards=3 notes=0 revlog=3
sync: replayed cards=3 notes=0 revlog=3
sync: pull chunks=0
sync: push pending cards=3 notes=0 revlog=3 graves=0
sync: push chunk=1 cards=3 notes=0 revlog=3 done=false
sync: finished server_mod=1793385699056 local_usn_now=258
sync: no changes local_mod=1793385699056 server_mod=1793385699056 usn=258/258   # 第二次
```

即：手机的牌组结构变更被自动接管（没有弹"需要整库同步"），本地 3 条复习连同
3 条 revlog 在接管后仍被推到 AnkiWeb，`sanityCheck2` 通过、`finish` 成功；紧接着
第二次同步是 `noChanges`，来回踢皮球的问题消失。

随后用 `harness/device_sync_evidence.lua` 在设备上重新下载服务器整库比对：

```
server:cards=1982,notes=1940,revlog=1588,decks=55,usn=259
local :cards=1982,notes=1940,revlog=1588,decks=55,usn=258
equal_rows=true
```

revlog 从 1585 涨到 1588，正是这次推送的 3 条复习——数据确实落到 AnkiWeb 上了。
