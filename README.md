# Timeline

**Color your thread.** 把待办、专注和笔记穿在同一根时间线上。

一个常驻在 macOS 后台的原生小工具：一个快捷键叫出来，记一笔、排一下、专注一会儿，再收回去。无需账号，数据只在你的 Mac 上。

![主界面：时间轴与月历](docs/screenshots/main.png)

## 能做什么

- **时间轴待办**：任务按日期串在一根线上，今天高亮、带「现在」线。上下拖动排序，拖过日期边界就改到那一天；`M` 推到明天。
- **月历**：一眼看出每天有几件事、专注了多久；把任务拖到某一天即可改期。
- **随手记录**：`⌃⌥L` 在任何应用里弹出，写一句日志或加一个待办，`@` 关联任务、`#` 打标签，支持粘贴图片（图里的文字也能搜到）。
- **专注计时**：从小时间轴上挑一个任务开始专注。计时时面板收成贴在屏幕边缘的透明小伙伴，悬停展开；结束后自动生成这一轮的小结。
- **笔记与日记**：每个任务、每个标签都是一本笔记；日记按时间线展开一天，顶部的节奏条显示什么时候在做什么。
- **工作板**：每个任务或标签一页 Markdown，所见即所得，支持待办勾选、折叠块、代码复制和 Vim 键位。
- **内置终端**：`⌃Tab` 随叫随到，支持标签页与分屏。

<p>
  <img src="docs/screenshots/focus-picker.png" width="49%" alt="从小时间轴选择专注任务">
  <img src="docs/screenshots/journal.png" width="49%" alt="日记：一天的时间线与专注小结">
</p>

## 快捷键

| 全局 | | 选中任务时 | |
| --- | --- | --- | --- |
| `⌃⌥D` | 主界面 | `空格` | 完成 |
| `⌃⌥L` | 快速记录 | `D` | 改截止日期 |
| `⌃⌥F` | 专注计时 | `M` / `⇧M` | 推到明天 / 提前一天 |
| `⌃⌥N` | 笔记与日记 | `F` | 开始专注 |
| `⌃⌥M` | 工作板 | `N` / `T` | 笔记 / 标签 |
| `⌃Tab` | 终端 | `?` | 全部快捷键 |

全局快捷键可在设置中修改。所有面板也能从菜单栏图标打开。

## 安装

需要 macOS 13 以上和 Swift 工具链。

```sh
bash scripts/install.sh   # 构建并安装到 ~/Applications，自动备份现有数据
```

数据保存在 `~/Library/Application Support/Timeline`，每天自动备份一份，可在应用内导出或恢复。

<details>
<summary>开发</summary>

```sh
swift build
swift test --filter TimelineCoreTests                               # 核心逻辑测试
TIMELINE_DESIGN_PREVIEW=/tmp/preview swift test --filter DesignPreviewTests   # 离屏渲染界面预览
```

工作板编辑器（CodeMirror）已离线打包进应用，构建不需要 Node.js。修改 `Editor/src` 后，在 `Editor` 目录运行 `npm ci && npm run build` 更新打包资源。

</details>
