# Timeline 迁移审计

仓库：`git@github.com:mokomoko05/Timeline.git`。新工作目录 `Timeline` 为独立克隆，不依赖旧仓库的 worktree 或对象目录。已移除另一个 worktree，其分支提交保留在 Git 历史与迁移前的仓库 bundle 中。

## 名称与身份

| 范围 | 迁移后 |
| --- | --- |
| Swift 包与主模块 | Timeline |
| 数据模块 | TimelineCore |
| 应用产品 | TimelineApp |
| 安装应用与包内可执行文件 | Timeline.app / Timeline |
| Bundle ID / 登录项 | local.timeline.app |
| 拖拽类型 | local.timeline.task |
| 数据目录 | Application Support/Timeline |

模块、测试目录、imports、资源文案与构建安装路径同步更新。命令行产品与后台接口已移除。

## 数据与偏好

- 安装前退出新旧应用。安装脚本在任何迁移写入前备份应用、数据、偏好和 LaunchAgent。
- 首次启动验证旧 journal 能解码且版本受支持，将旧目录复制到临时目录，校验 journal 未在复制期间改变，最后原子改名为 Timeline。socket 不复制。
- 复制保留图片、备份、草稿、标签、任务编号、笔记和专注记录；不修改旧目录。读取失败时停止迁移，不创建空白新版数据。
- 目标已存在时不覆盖；目标目录存在但没有 journal 时停止迁移，要求检查目录，避免静默跳过旧数据。
- `TIMELINE_DATA_DIR` 优先，旧 `DAYLEAF_DATA_DIR` 仍可用。指定目录时不迁移默认数据。
- 偏好复制到 `local.timeline.app`，重命名窗口位置中的 Dayleaf 键；已有新值优先，只复制一次，后续启动不恢复旧设置。
- 新版 Bundle ID 有独立权限，需要重新允许通知。原应用的系统授权与通知历史不删除。

## 安装与清理

- 通用安装器保留旧应用及原始数据，安装 Timeline.app。本次本机清理经过单独授权，在核对独立备份、新数据、登录项和 Git 历史后删除旧 Scheduler.app、Dayleaf 数据目录和原 Dayleaf 仓库。迁移兼容代码保留供其他旧版安装使用。
- 新登录项配置成功后，停用旧登录项并将其配置归档，避免下次登录同时启动两个版本。
- `timeline`、`sched`、`scheduler` 命令及 socket 服务已移除。安装器清理旧应用包工具目录，只删除指向新旧应用包的命令链接，不删除其他同名程序。
- 新版启动时检测旧 Bundle ID 是否运行，防止两份应用同时占用快捷键或误用不同数据副本。
- 内置终端保留，直接加载用户 zsh 配置和 ZDOTDIR，不再注入命令目录或禁用 zsh 的 sched 内置命令。图片渲染识别 Timeline，并保留 Scheduler 终端名称兼容。

## UI

图标采用深色圆角底、蓝色纵轴与三个节点。主界面每个日期分组内，以细灰线连接优先级色点，连接线随行高变化，分组间断开。色点仍可展开优先级菜单；完成按钮放在卡片内，避免将重要性和完成状态混为一种操作。截止日期、专注、标签、拖拽和键盘操作保留，排序规则不变。

完成后保留日期分组和原排序位置，收为优先级圆点与一行划线标题；点标题或右键「取消完成」恢复。未完成卡片通过轻微渐变、阴影和短连接线形成层次，悬停不改变大小，拖动松手仍立即复位。完整 419 项测试通过，新增覆盖完成后的排序、撤销、重启与大字号单行布局。

## 验证与回退

运行 `swift test --disable-sandbox`、`bash -n scripts/build.sh scripts/install.sh`，再运行安装脚本。安装后核对任务与日志标识、图片、备份、偏好、登录项、旧命令入口已移除、代码签名及旧文件校验值。

本次执行结果：完整 481 项测试通过；构建、安装、代码签名检查及 CLI 与新版应用通信通过。实际迁移后的完整 journal 与旧文件内容一致，图片及备份逐文件一致，偏好完成复制和窗口键名迁移；旧应用逐文件校验未变，旧登录项归档、新登录项加载成功。迁移审计报告写入仓库外的备份目录，不把用户数据纳入 Git。

清理前再次核对：36 项任务和 345 条日志内容一致，38 张图片和 15 份备份逐文件一致；旧应用与独立备份一致，新数据无符号链接，登录项只指向新版，Git bundle 验证通过。

移除命令行后完整 417 项测试通过，包含优先级时间线、任务布局、拖放及用户 zsh 配置加载验证；已移除的命令行测试随对应功能删除。

独立备份目录 `../Timeline-migration-backup-20261020-101933/` 保留旧应用、原数据、偏好、登录配置和完整 `repository.bundle`；安装器另在 `~/Library/Application Support/Timeline Migration Backups/` 保存更新前副本。

README 截图使用示例数据生成。运行 `python3 scripts/screenshots.py` 可重建；脚本使用临时数据目录和独立 Bundle ID，避免改动实际记录与偏好。

回退时先退出 Timeline，停用 `local.timeline.app` 登录项，从备份恢复 Scheduler.app、Dayleaf 数据及旧偏好，按需恢复旧登录配置。原仓库可通过 `git clone repository.bundle Dayleaf` 重建。迁移后的新增内容只在 Timeline 数据中，回退前应通过应用导出；不要直接用旧数据覆盖新版目录。
