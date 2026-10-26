#!/bin/bash
# 用免费 Apple ID（个人团队）签名 iPhone 版 Timeline 并装到手机上。
#
#   bash scripts/install-ios.sh              构建、签名、安装并打开
#   bash scripts/install-ios.sh --schedule   另外装一个登录项，每天检查一次，距上次安装超过 4 天就自动重装（免费签名 7 天过期）
#   bash scripts/install-ios.sh --unschedule 取消自动重装
#   bash scripts/install-ios.sh --auto       （登录项调用）未到期或手机不在线时安静退出
#
# 可用环境变量覆盖：TIMELINE_TEAM_ID（团队 ID）、TIMELINE_DEVICE（设备 UDID）、TIMELINE_BUNDLE_ID。
# 重装不会清除手机上的数据。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
LABEL="local.timeline.ios-reinstall"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_DIR="$HOME/Library/Application Support/Timeline iOS Install"
STAMP="$STATE_DIR/last-install"
LOG_DIR="$HOME/Library/Logs/Timeline"
MODE="${1:-}"

case "$MODE" in
--unschedule)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$AGENT"
    echo "已取消自动重装。"
    exit 0
    ;;
--schedule)
    mkdir -p "$(dirname "$AGENT")" "$LOG_DIR"
    cat >"$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>/bin/bash</string><string>$ROOT/scripts/install-ios.sh</string><string>--auto</string></array>
    <key>StartInterval</key><integer>21600</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$LOG_DIR/ios-install.log</string>
    <key>StandardErrorPath</key><string>$LOG_DIR/ios-install.log</string>
</dict>
</plist>
PLIST
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENT"
    echo "已设置自动重装：每 6 小时检查一次，距上次安装超过 4 天且手机在线（同一 Wi-Fi 或连着线）时重装。日志：$LOG_DIR/ios-install.log"
    exit 0
    ;;
--auto)
    echo "=== $(date '+%F %T') 检查是否需要重装"
    if [ -f "$STAMP" ] && [ $(( $(date +%s) - $(cat "$STAMP") )) -lt $((4 * 86400)) ]; then
        echo "距上次安装不到 4 天，跳过。"
        exit 0
    fi
    ;;
"") ;;
*) echo "未知参数：$MODE" >&2; exit 2 ;;
esac

fail() { echo "✗ $1" >&2; exit 1; }

# 团队 ID：Xcode 设置 › 账户里登录 Apple ID 后，个人团队会记在 Xcode 的偏好里。
TEAM="${TIMELINE_TEAM_ID:-}"
if [ -z "$TEAM" ]; then
    TEAM="$(defaults export com.apple.dt.Xcode - 2>/dev/null | python3 -c '
import plistlib, sys
try:
    prefs = plistlib.loads(sys.stdin.buffer.read())
except Exception:
    sys.exit(0)
teams = []
for value in (prefs.get("IDEProvisioningTeamByIdentifier") or {}).values():
    teams += value if isinstance(value, list) else [value]
for value in (prefs.get("IDEProvisioningTeams") or {}).values():
    teams += value if isinstance(value, list) else [value]
teams = [t for t in teams if isinstance(t, dict) and t.get("teamID")]
teams.sort(key=lambda t: not t.get("isFreeProvisioningTeam", False))
print(teams[0]["teamID"] if teams else "")
')"
fi
# 偏好里没有时，从钥匙串里的 Apple Development 证书读团队 ID（证书主题的 OU）。
if [ -z "$TEAM" ]; then
    TEAM="$(security find-certificate -a -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null \
        | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1 || true)"
fi
[ -n "$TEAM" ] || fail "找不到签名团队。请打开 Xcode › 设置 › 账户，用 Apple ID 登录，选中账户后点「Manage Certificates…」› + › Apple Development 创建证书，再重试（或设置 TIMELINE_TEAM_ID）。"

# 免费团队的 Bundle ID 在全苹果范围内必须唯一：带上团队 ID。
BUNDLE_ID="${TIMELINE_BUNDLE_ID:-local.timeline.mobile.$(echo "$TEAM" | tr '[:upper:]' '[:lower:]')}"

# 设备：第一台已配对、可连接的 iPhone。
DEVICE_JSON="$(mktemp)"
trap 'rm -f "$DEVICE_JSON"' EXIT
xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null 2>&1 || true
read -r DEVICE UDID NAME < <(python3 - "$DEVICE_JSON" "${TIMELINE_DEVICE:-}" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
wanted = sys.argv[2]
for device in devices:
    hardware = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    if hardware.get("platform") != "iOS" or connection.get("pairingState") != "paired":
        continue
    if wanted and wanted not in (device.get("identifier"), hardware.get("udid")):
        continue
    if connection.get("tunnelState") == "unavailable":
        continue
    name = device.get("deviceProperties", {}).get("name", "iPhone").replace(" ", "_")
    print(device["identifier"], hardware.get("udid", ""), name)
    break
else:
    print("", "", "")
PY
)
if [ -z "$DEVICE" ]; then
    [ "$MODE" = "--auto" ] && { echo "手机不在线，稍后再试。"; exit 0; }
    fail "找不到可用的 iPhone。请用数据线连接 iPhone 并在手机上点「信任」；首次还需在 Xcode › Window › Devices and Simulators 里配对，并勾选「Connect via network」以便之后无线安装。"
fi
echo "→ 设备：${NAME//_/ }（${UDID}），团队：${TEAM}，Bundle ID：${BUNDLE_ID}"

BUILD="$ROOT/.build/ios"
echo "→ 构建并签名…"
xcodebuild -project iOS/TimelineMobile.xcodeproj -scheme TimelineMobile -configuration Release \
    -destination "id=$UDID" -derivedDataPath "$BUILD" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$TEAM" TIMELINE_BUNDLE_ID="$BUNDLE_ID" \
    build -quiet || fail "构建或签名失败（见上方输出）。"

APP="$BUILD/Build/Products/Release-iphoneos/Timeline.app"
echo "→ 安装到手机…"
xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null || fail "安装失败。请确认手机已解锁，并已在 设置 › 隐私与安全性 › 开发者模式 中打开开发者模式。"
mkdir -p "$STATE_DIR"
date +%s >"$STAMP"
echo "→ 打开应用…"
if ! xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1; then
    echo "  无法自动打开。首次安装需在手机 设置 › 通用 › VPN与设备管理 里信任你的开发者证书，然后手动打开 Timeline。"
fi
echo "✓ 已安装 iPhone 版 Timeline。免费签名 7 天后过期，过期前重新运行本脚本（或用 --schedule 自动重装），数据会保留。"
