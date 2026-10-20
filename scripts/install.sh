#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build.sh
TARGET="$HOME/Applications/Timeline.app"
for NAME in Timeline Scheduler Dayleaf; do
    if pgrep -f "$HOME/Applications/$NAME.app/Contents/MacOS/$NAME" >/dev/null 2>&1; then
        echo "请先退出 ${NAME}，再重新运行安装脚本。应用及数据会保留。"
        exit 1
    fi
done
BACKUP="$HOME/Library/Application Support/Timeline Migration Backups/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$BACKUP/Applications" "$BACKUP/Data" "$BACKUP/Preferences" "$BACKUP/LaunchAgents"
for NAME in Timeline Scheduler Dayleaf; do
    if [ -d "$HOME/Applications/$NAME.app" ]; then
        ditto "$HOME/Applications/$NAME.app" "$BACKUP/Applications/$NAME.app"
    fi
done
for NAME in Timeline Dayleaf; do
    if [ -d "$HOME/Library/Application Support/$NAME" ]; then
        ditto "$HOME/Library/Application Support/$NAME" "$BACKUP/Data/$NAME"
    fi
done
for DOMAIN in local.dayleaf.app local.timeline.app; do
    if defaults read "$DOMAIN" >/dev/null 2>&1; then
        defaults export "$DOMAIN" "$BACKUP/Preferences/$DOMAIN.plist"
    fi
    AGENT="$HOME/Library/LaunchAgents/$DOMAIN.plist"
    if [ -f "$AGENT" ]; then cp "$AGENT" "$BACKUP/LaunchAgents/"; fi
done
echo "迁移前备份：$BACKUP"
mkdir -p "$HOME/Applications"
ditto "dist/Timeline.app" "$TARGET"
rm -rf "$TARGET/Contents/Resources/bin"
"$TARGET/Contents/MacOS/Timeline" --migrate-legacy
"$TARGET/Contents/MacOS/Timeline" --configure-login
LEGACY_AGENT="$HOME/Library/LaunchAgents/local.dayleaf.app.plist"
if [ -f "$LEGACY_AGENT" ]; then
    launchctl bootout "gui/$(id -u)/local.dayleaf.app" >/dev/null 2>&1 || true
    mv "$LEGACY_AGENT" "$BACKUP/LaunchAgents/local.dayleaf.app.disabled.plist"
fi
for NAME in timeline sched scheduler; do
    LINK="$HOME/.local/bin/$NAME"
    if [ -L "$LINK" ]; then
        case "$(readlink "$LINK")" in
            "$HOME/Applications/Timeline.app/Contents/Resources/bin/"*|"$HOME/Applications/Scheduler.app/Contents/Resources/bin/"*|"$HOME/Applications/Dayleaf.app/Contents/Resources/bin/"*) rm "$LINK" ;;
        esac
    fi
done
if open "$TARGET"; then
    echo "已安装并请求打开 Timeline；登录启动状态可在应用右上角菜单查看。"
else
    echo "安装完成。当前环境无法打开桌面应用，请在 Finder 中打开：$TARGET"
fi
