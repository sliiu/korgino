# 任务板

方案：`docs/adr/0072-one-main-window.md`，设计：`docs/design/2026-11-09-main-window.md`。分支 `design/main-panel`。

| 编号 | 任务 | 执行者 | 状态 | PR | 备注 |
|---|---|---|---|---|---|
| P0 | ADR 0072 + 主窗口与设置设计稿 | self | 🔄 进行 | — | 待用户看稿 |
| P1 | 主窗口骨架：常规应用、侧栏、翻译/实时与会议/历史三页（现有视图嵌入） | feature | ⏸ 待授权 | — | 依赖 P0 |
| P2 | 菜单栏精简为 4 行，旧快捷键指向主窗口对应页，权限横条 | feature | ⏸ 待授权 | — | 依赖 P1 |
| P3 | 设置进主窗口：常用一页 + 高级 7 页 | feature | ⏸ 待授权 | — | 依赖 P1，和 P2 改不同文件可并行 |
| P4 | 更多：词典、媒体字幕、语音页嵌入 | quick-ui | ⏸ 待授权 | — | 依赖 P1 |
| P5 | Windows 对齐 | — | ⬜ 待办 | — | Mac 完成后另起 ADR |

## 注意

- 主目录 `main` 上有未提交改动（`Info.plist`、`main.swift`、`LaunchLog.swift`），不是本任务的，不碰。
- `t3/launch-permissions-captions` 也在改 `main.swift` 启动部分，P1/P2 合并前要对一下冲突。
