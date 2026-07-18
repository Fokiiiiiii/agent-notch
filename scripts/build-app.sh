#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# ~/Documents は iCloud 同期対象で SQLite の build.db が disk I/O error を起こすため、
# ビルド成果物は同期外の ~/.cache に置く。
SCRATCH="$HOME/.cache/agent-notch/build"
swift build -c release --scratch-path "$SCRATCH"
APP=build/AgentNotch.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SCRATCH/release/AgentNotch" "$APP/Contents/MacOS/AgentNotch"
cp "$SCRATCH/release/agent-notch-bridge" "$APP/Contents/MacOS/agent-notch-bridge"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.chaos.agent-notch</string>
    <key>CFBundleName</key>
    <string>AgentNotch</string>
    <key>CFBundleExecutable</key>
    <string>AgentNotch</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
EOF
echo "Built: $APP"
