#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
"$PROJECT_DIR/scripts/build-app.sh"
TARGET_DIR="$HOME/Applications"
TARGET_APP="$TARGET_DIR/CodexTouchBar.app"
mkdir -p "$TARGET_DIR"
if pgrep -x CodexTouchBar >/dev/null; then
    printf '%s\n' '请先从菜单栏退出 Codex Touch Bar，再运行安装脚本。'
    exit 1
fi
if [ -e "$TARGET_APP" ]; then
    # Keep the previous app so installation is reversible.
    mv "$TARGET_APP" "$TARGET_DIR/CodexTouchBar.previous.$(date +%Y%m%d-%H%M%S).app"
fi
ditto "$PROJECT_DIR/dist/CodexTouchBar.app" "$TARGET_APP"
open "$TARGET_APP"
printf '已安装：%s\n' "$TARGET_APP"
