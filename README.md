# Timeline

把待办、专注和随手记，留在同一条时间线上。

一个 macOS 原生小工具。安排今天要做的事，用快捷键记下想法，再留一段时间认真做完。无需账号，内容保存在本机。

![Timeline 主界面：彩色节点连接任务，已完成事项收为一行](docs/screenshots/main.png)

## 用快捷键打开

| 默认快捷键 | 界面 |
| --- | --- |
| `⌃⌥D` | 主界面：待办时间线与月历 |
| `⌃⌥L` | 快速记录：随手写日志，也能切换到创建待办 |
| `⌃⌥F` | 专注工作台：选一件事，写下目标，开始计时 |
| `⌃N` | 笔记 / 日记：按标签整理，或按日期回看 |
| `⌃⌥T` | 内置终端 |

`⌃` 是 Control，`⌥` 是 Option。快捷键可以在设置里修改。

## 随手记，不打断

一个留在桌面上的小输入框。文字、图片、临时想到的待办，都可以先记下来。

<img src="docs/screenshots/capture.png" alt="快速记录面板" width="380">

`Enter` 换行，`⌘Enter` 保存。`@` 关联任务，`#` 添加标签。

## 给一件事留点时间

选好任务，写下这轮想完成什么。倒计时和笔记栏留在手边，查资料、换窗口都不影响计时；到点后，记一段简短反馈。

<img src="docs/screenshots/focus.png" alt="专注工作台：本轮目标、快速笔记与倒计时" width="380">

## 回看今天，也整理长期的笔记

同一个窗口，切换 Notes 和 Journal。按标签找笔记，按日期看日志；每段专注都有目标、时间戳和阶段反馈。

![日记界面：按日期回看记录与专注时间线](docs/screenshots/daylog.png)

截图均使用示例数据。

## 安装

需要 macOS 13 或更高版本，以及 Xcode 或 Swift 命令行工具。在仓库目录运行：

```sh
bash scripts/install.sh
```

应用安装到 `~/Applications/Timeline.app`，更新前请先退出。

数据保存在 `~/Library/Application Support/Timeline/`，支持自动备份、导出和恢复。旧版迁移说明见 [MIGRATION.md](MIGRATION.md)。

[MIT License](LICENSE)
