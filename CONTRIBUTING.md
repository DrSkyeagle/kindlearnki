# 参与开发

欢迎 issue 与 PR。这个项目是"只做四件事"的插件（牌组 / 复习 / 同步 / 登录），
范围之外的浏览器、编辑器、统计、导入导出都不打算做。

## 本地环境

- 任意 LuaJIT 5.1（Windows 可直接用仓库自带的 `tools/lj/luajit.exe`）
- 跑离线测试（不需要 KOReader、不需要联网）：

  ```bash
  ./tools/lj/luajit.exe kindlearnki.koplugin/tests/run.lua
  ```

- 想覆盖"真卡片真模板/真调度"的用例，再给一个真实集合：

  ```bash
  KINDLEARNKI_TEST_COLLECTION=/path/to/collection.anki2 \
    ./tools/lj/luajit.exe kindlearnki.koplugin/tests/run.lua
  ```

## 提交前

1. `tests/run.lua` 全绿（当前 234 例）。
2. 改到界面/渲染时，至少跑一遍 L2 截图回归（命令见 `doc/验收.md`）。
3. 改到同步时，跑 `bash harness/run_sync_e2e.sh`（对 mock AnkiWeb 的三种模式）。
4. 新增对 Anki 行为的断言时，**在注释里写明依据**（rslib/AnkiDroid 的文件与行号，
   或真机实测），这是这个仓库一贯的做法。

## 代码约定

- 中文注释/日志可以，代码标识符用英文；面向用户的文案走 `gettext`。
- 不做"顺手重构"：一个 PR 一件事。
- 崩溃与数据丢失优先于新功能。

## 提交信息

一句话说清"改了什么、为什么"，可以带 scope，例如：

```
fix(sync): keep the collection object alive across a full download
```
