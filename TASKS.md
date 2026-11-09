# 任务板

方案：`docs/adr/0072-one-main-window.md`，设计：`docs/design/2026-11-09-main-window.md`。分支 `design/main-panel`。

| 编号 | 任务 | 执行者 | 状态 | PR | 备注 |
|---|---|---|---|---|---|
| P0 | ADR 0072 + 主窗口、设置、浮层与基础样式设计稿 | self | ✅ 完成 | — | 用户已通过设计稿；效果图在 docs/design/mockups，待看图确认 |
| P1 | 主窗口骨架：常规应用、侧栏、翻译/实时与会议/历史三页（现有视图嵌入） | feature | ⏸ 待授权 | — | 依赖 P0 |
| P2 | 菜单栏精简为 4 行，旧快捷键指向主窗口对应页，权限横条 | feature | ⏸ 待授权 | — | 依赖 P1 |
| P3 | 设置进主窗口：常用一页 + 高级 7 页 | feature | ⏸ 待授权 | — | 依赖 P1，和 P2 改不同文件可并行 |
| P4 | 更多：词典、媒体字幕、语音页嵌入 | quick-ui | ⏸ 待授权 | — | 依赖 P1 |
| P5 | 基础：`Theme.Type` 七档字号、语义色、`StatusDot`、`ErrorLine` 两种，全应用替换 + 构建检查 | bulk | ⏸ 待授权 | — | 不依赖主窗口，可先做 |
| P6 | 浮层重做：翻译浮层、快捷翻译浮标、语音胶囊（与浮标拆开）、划词插件条、沉浸字幕 | feature | ⏸ 待授权 | — | 依赖 P5 |
| P7 | Windows 对齐 | — | ⬜ 待办 | — | Mac 完成后另起 ADR |

## 注意

- 主目录 `main` 上有未提交改动（`Info.plist`、`main.swift`、`LaunchLog.swift`），不是本任务的，不碰。
- `t3/launch-permissions-captions` 也在改 `main.swift` 启动部分，P1/P2 合并前要对一下冲突。
