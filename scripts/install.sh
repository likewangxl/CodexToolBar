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
STAGING="$(mktemp -d "$TARGET_DIR/.codextoolbar-install.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto "$PROJECT_DIR/dist/CodexTouchBar.app" "$STAGING/CodexTouchBar.app"
codesign --verify --strict "$STAGING/CodexTouchBar.app"
if [ -e "$TARGET_APP" ]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$TARGET_APP" || true
    rm -rf "$TARGET_APP"
fi
mv "$STAGING/CodexTouchBar.app" "$TARGET_APP"
rm -rf "$PROJECT_DIR/dist/CodexTouchBar.app"
open "$TARGET_APP"
printf '已安装：%s\n' "$TARGET_APP"
