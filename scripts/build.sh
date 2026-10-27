#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --disable-sandbox -c release
APP="$(pwd)/dist/Timeline.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .build/AppIcon.iconset
cp .build/release/TimelineApp "$APP/Contents/MacOS/Timeline"
ditto .build/release/Timeline_Timeline.bundle "$APP/Contents/Resources/Timeline_Timeline.bundle"
rm -rf "$APP/Contents/Resources/Timeline_TimelineMath.bundle"
ditto .build/release/Timeline_TimelineMath.bundle "$APP/Contents/Resources/Timeline_TimelineMath.bundle"
rm -rf "$APP/Contents/Resources/bin"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -d Resources/en.lproj ]; then cp -R Resources/en.lproj "$APP/Contents/Resources/"; fi
if [ -d Resources/zh-Hans.lproj ]; then cp -R Resources/zh-Hans.lproj "$APP/Contents/Resources/"; fi
swift scripts/make-icon.swift .build/icon.png
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" .build/icon.png --out ".build/AppIcon.iconset/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" .build/icon.png --out ".build/AppIcon.iconset/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
swift scripts/pack-icons.swift .build/AppIcon.iconset "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
echo "构建完成：$APP"
