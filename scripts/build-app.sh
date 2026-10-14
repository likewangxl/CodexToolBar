#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
swift build -c release
APP_PATH="$PROJECT_DIR/dist/CodexTouchBar.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp .build/release/CodexTouchBar "$APP_PATH/Contents/MacOS/CodexTouchBar"
cp Info.plist "$APP_PATH/Contents/Info.plist"
cp README.md "$APP_PATH/Contents/Resources/README.md"
cp LICENSE NOTICE.md "$APP_PATH/Contents/Resources/"
bash "$PROJECT_DIR/scripts/build-icon.sh" "$APP_PATH/Contents/Resources/AppIcon.icns"
if [ -f Sources/CodexTouchBar/Resources/QuotaIcon.png ]; then
    cp Sources/CodexTouchBar/Resources/QuotaIcon.png "$APP_PATH/Contents/Resources/QuotaIcon.png"
else
    rm -f "$APP_PATH/Contents/Resources/QuotaIcon.png"
fi
codesign --force --sign - "$APP_PATH"
codesign --verify --strict "$APP_PATH"
printf '%s\n' "$APP_PATH"
