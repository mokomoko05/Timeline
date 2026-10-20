# Timeline 迁移审计

仓库：`git@github.com:mokomoko05/Timeline.git`。新工作目录为 `Timeline`；原 Dayleaf 工作目录保留。已移除另一个 worktree，其分支提交保留在 Git 历史与迁移前的仓库 bundle 中。

## 名称与身份

| 范围 | 迁移后 |
| --- | --- |
| Swift 包与主模块 | Timeline |
| 数据模块 / CLI 模块 | TimelineCore / TimelineKit |
| CLI 源码目标 | TimelineCLI |
| 应用产品 / 命令行产品 | TimelineApp / timeline |
| 安装应用与包内可执行文件 | Timeline.app / Timeline |
| Bundle ID / 登录项 | local.timeline.app |
| 拖拽类型 | local.timeline.task |
| 数据目录 | Application Support/Timeline |
| socket | timeline.sock；长路径使用 /tmp/timeline-目录哈希.sock |

应用构建产品与命令行产品使用不同名称，避免默认不区分大小写的 macOS 文件系统把 `Timeline` 和 `timeline` 当成同一个文件。模块、测试目录、imports、资源文案与构建安装路径同步更新。

## 数据与偏好

- 安装前退出新旧应用。安装脚本在任何迁移写入前备份应用、数据、偏好和 LaunchAgent。
- 首次启动验证旧 journal 能解码且版本受支持，将旧目录复制到临时目录，校验 journal 未在复制期间改变，最后原子改名为 Timeline。socket 不复制。
- 复制保留图片、备份、草稿、标签、任务编号、笔记和专注记录；不修改旧目录。读取失败时停止迁移，不创建空白新版数据。
- 目标已存在时不覆盖；目标目录存在但没有 journal 时停止迁移，要求检查目录，避免静默跳过旧数据。
- GUI 与 CLI 使用相同的数据路径解析。`TIMELINE_DATA_DIR` 优先，旧 `DAYLEAF_DATA_DIR` 仍可用。指定目录时不迁移默认数据。
- 偏好复制到 `local.timeline.app`，重命名窗口位置中的 Dayleaf 键；已有新值优先，只复制一次，后续启动不恢复旧设置。
- 新版 Bundle ID 有独立权限，需要重新允许通知。原应用的系统授权与通知历史不删除。

## 安装与命令行

- 保留 Scheduler.app、Dayleaf.app 及原始数据，安装 Timeline.app。
- 新登录项配置成功后，停用旧登录项并将其配置归档，避免下次登录同时启动两个版本。
- `timeline`、`sched`、`scheduler` 指向新版命令行。旧命令名称兼容，新旧 socket 不互通。
- 新版启动时检测旧 Bundle ID 是否运行，防止两份应用同时占用快捷键或误用不同数据副本。
- 内置终端更新 TERM_PROGRAM、工具目录与测试；图片渲染识别 Timeline，并保留 Scheduler 终端名称兼容。

## UI

图标采用深色圆角底、蓝色纵轴与三个节点。主界面每个日期分组内，任务完成按钮成为时间线节点，连接线随行高变化；分组间断开。优先级色点、截止日期、专注、标签、拖拽和键盘操作保留，排序规则不变。

## 验证与回退

运行 `swift test --disable-sandbox`、`bash -n scripts/build.sh scripts/install.sh`，再运行安装脚本。安装后核对任务与日志标识、图片、备份、偏好、登录项、CLI 状态、代码签名及旧文件校验值。

本次执行结果：完整 481 项测试通过；构建、安装、代码签名检查及 CLI 与新版应用通信通过。实际迁移后的完整 journal 与旧文件内容一致，图片及备份逐文件一致，偏好完成复制和窗口键名迁移；旧应用逐文件校验未变，旧登录项归档、新登录项加载成功。迁移审计报告写入仓库外的备份目录，不把用户数据纳入 Git。

回退时先退出 Timeline，停用 `local.timeline.app` 登录项，再打开保留的 Scheduler.app；原始旧数据和旧偏好仍在。需要恢复旧登录项时使用安装备份中的 plist。迁移后的新增内容只在 Timeline 数据中，回退前应通过应用导出；不要直接用旧数据覆盖新版目录。
