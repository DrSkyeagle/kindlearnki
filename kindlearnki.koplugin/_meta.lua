-- KOReader plugin metadata.  `name` comes from the directory name
-- (kindlearnki.koplugin); a `name` key here is ignored by PluginLoader and logs
-- a deprecation warning, so it is deliberately absent.
--
-- The version string is not duplicated: PluginLoader puts the plugin root on
-- package.path before loading this file, so `core.version` resolves here.

local Version = require("core.version")

return {
    fullname = string.format("Kindlearnki 复习器 %s", Version.VERSION),
    description = [[
在越狱的 Kindle（KOReader ≥ v2026.07.1）上复习 Anki 卡片，并与 AnkiWeb 双向同步。

· 安装：把 kindlearnki.koplugin 整个目录放到 koreader/plugins/ 下，重启 KOReader
· 入口：工具（扳手）标签页底部，或主菜单标签页底部；也可绑成手势动作
· 本地维护一份真实的 schema-18 数据库，复习进度按 AnkiWeb 协议 v11 同步
· 调度对齐 Anki v3 语义（三队列、限额、学习步、leech、兄弟卡 bury、凌晨跨天）
· 卡片按 HTML 排版（粗体/表格/列表/颜色），图片按需下载；音频与 JS 明确不支持
· 只保存同步密钥，不保存密码
]],
}
