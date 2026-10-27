#!/bin/bash
# 生成 README 截图：用示例数据离屏渲染（不开窗口、不打扰前台），英文界面、深色外观。
#
# `swift test` 的主 bundle 是 Xcode 里的 xctest，没有应用的 strings，SwiftUI 文案会落回中文原文：
# 这里把 xctest 复制到临时目录、旁边放上 Resources 里的 .lproj，再用它跑渲染测试。
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
RUNNER="$(mktemp -d)"
trap 'rm -rf "$OUT" "$RUNNER"' EXIT
swift build --build-tests >/dev/null
DEV="$(xcode-select -p)"
PLATFORM="$DEV/Platforms/MacOSX.platform/Developer"
mkdir -p "$RUNNER/usr/bin"
cp "$DEV/usr/bin/xctest" "$RUNNER/usr/bin/"
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$RUNNER/usr/bin/"
DYLD_FRAMEWORK_PATH="$PLATFORM/Library/Frameworks" DYLD_LIBRARY_PATH="$PLATFORM/usr/lib" \
TIMELINE_DESIGN_PREVIEW="$OUT" TIMELINE_PREVIEW_LANGUAGE=english \
    "$RUNNER/usr/bin/xctest" -XCTest TimelineUITests.DesignPreviewTests "$(swift build --show-bin-path)/TimelinePackageTests.xctest" >/dev/null
python3 - "$OUT" <<'EOF'
import shutil, sys
from PIL import Image
src, dst = sys.argv[1], "docs/screenshots"
def fit(image, width=1440):
    return image.resize((width, int(width * image.height / image.width)), Image.LANCZOS)
fit(Image.open(f"{src}/main-dark.png")).save(f"{dst}/main.png", optimize=True)
fit(Image.open(f"{src}/journal-dark.png")).save(f"{dst}/journal.png", optimize=True)
fit(Image.open(f"{src}/notes-dark.png")).save(f"{dst}/notes.png", optimize=True)
fit(Image.open(f"{src}/notebook-chapters-dark.png")).save(f"{dst}/notebook.png", optimize=True)
picker = Image.open(f"{src}/picker-dark.png")
picker.crop((0, int(picker.height * 0.2), picker.width, picker.height)).save(f"{dst}/focus-picker.png", optimize=True)
Image.open(f"{src}/companion-dark.png").save(f"{dst}/focus.png", optimize=True)
Image.open(f"{src}/capture-dark.png").save(f"{dst}/capture.png", optimize=True)
Image.open(f"{src}/search-dark.png").save(f"{dst}/search.png", optimize=True)
# iPhone 截图（scripts/screenshots-ios.sh）用同一份示例数据。
shutil.copy(f"{src}/sample-journal.json", ".build/screenshot-sample.json")
print("Updated docs/screenshots")
EOF
