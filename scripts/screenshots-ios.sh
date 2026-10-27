#!/bin/bash
# 生成 README 的 iPhone 截图：在已启动的模拟器里装上检查版应用，放入 scripts/screenshots.sh 生成的示例数据，
# 英文界面、深色外观，拍待办、日记、待办笔记页和工作板四张，拼成 docs/screenshots/ios.png。
# 先跑 scripts/screenshots.sh（会写 .build/screenshot-sample.json）。
set -euo pipefail
cd "$(dirname "$0")/.."
SAMPLE=.build/screenshot-sample.json
[ -f "$SAMPLE" ] || { echo "先运行 scripts/screenshots.sh" >&2; exit 1; }
ID=local.timeline.mobile.check
APP=.build/ios-sim/Build/Products/Release-iphonesimulator/Timeline.app
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
xcodebuild -project iOS/TimelineMobile.xcodeproj -scheme TimelineMobile -configuration Release -sdk iphonesimulator \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath .build/ios-sim TIMELINE_BUNDLE_ID=$ID build >/dev/null
xcrun simctl terminate booted $ID 2>/dev/null || true
xcrun simctl uninstall booted $ID
xcrun simctl install booted "$APP"
DATA="$(xcrun simctl get_app_container booted $ID data)/Library/Application Support/Timeline"
mkdir -p "$DATA"
cp "$SAMPLE" "$DATA/journal.json"
xcrun simctl ui booted appearance dark
xcrun simctl status_bar booted override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
shoot() {
    local name=$1; shift
    xcrun simctl terminate booted $ID 2>/dev/null || true
    xcrun simctl launch booted $ID -AppleLanguages "(en)" -AppleLocale en_US "$@" >/dev/null
    sleep 9
    xcrun simctl io booted screenshot "$OUT/$name.png" >/dev/null 2>&1
}
shoot tasks -startTab tasks
shoot journal -startTab journal
shoot task -startTab tasks -perfProbe YES -perfActions YES -perfSteps "打开笔记多的待办" -perfRounds 1
shoot board -startTab boards -perfProbe YES -perfActions YES -perfSteps "切到工作板,打开工作板" -perfRounds 1
xcrun simctl terminate booted $ID 2>/dev/null || true
xcrun simctl status_bar booted clear
python3 - "$OUT" <<'EOF'
import sys
from PIL import Image
src = sys.argv[1]
width, gap = 420, 24
shots = [Image.open(f"{src}/{name}.png").convert("RGB") for name in ["tasks", "journal", "task", "board"]]
shots = [shot.resize((width, int(width * shot.height / shot.width)), Image.LANCZOS) for shot in shots]
strip = Image.new("RGB", (len(shots) * width + (len(shots) - 1) * gap, shots[0].height), (13, 17, 23))
for index, shot in enumerate(shots):
    strip.paste(shot, (index * (width + gap), 0))
strip.save("docs/screenshots/ios.png", optimize=True)
print("Updated docs/screenshots/ios.png")
EOF
