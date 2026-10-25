#!/bin/bash
# 生成 README 截图：用示例数据离屏渲染（不开窗口、不打扰前台），中文界面、深色外观。
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
TIMELINE_DESIGN_PREVIEW="$OUT" TIMELINE_PREVIEW_LANGUAGE=chinese swift test --filter DesignPreviewTests >/dev/null
python3 - "$OUT" <<'EOF'
import sys
from PIL import Image
src, dst = sys.argv[1], "docs/screenshots"
def fit(image, width=1440):
    return image.resize((width, int(width * image.height / image.width)), Image.LANCZOS)
main = Image.open(f"{src}/main-dark.png")
fit(main.crop((0, 0, main.width, int(main.width * 0.64)))).save(f"{dst}/main.png", optimize=True)
fit(Image.open(f"{src}/journal-dark.png")).save(f"{dst}/journal.png", optimize=True)
picker = Image.open(f"{src}/picker-dark.png")
picker.crop((0, int(picker.height * 0.26), picker.width, picker.height)).save(f"{dst}/focus-picker.png", optimize=True)
Image.open(f"{src}/companion-dark.png").save(f"{dst}/focus.png", optimize=True)
print("Updated docs/screenshots")
EOF
