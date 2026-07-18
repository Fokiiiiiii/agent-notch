#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# ~/Documents は iCloud 同期対象で SQLite の build.db が disk I/O error を起こすため、
# ビルド成果物は同期外の ~/.cache に置く。
SCRATCH="$HOME/.cache/agent-notch/build"
swift build -c release --scratch-path "$SCRATCH"
ADAPTER_SOURCE="Vendor/MediaRemoteAdapter"
ADAPTER_DYLIB="$SCRATCH/MediaRemoteAdapter.dylib"
/usr/bin/clang -dynamiclib -fobjc-arc -fvisibility=default -O2 \
    -I"$ADAPTER_SOURCE/include" -I"$ADAPTER_SOURCE/src" \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -o "$ADAPTER_DYLIB" \
    "$ADAPTER_SOURCE/src/adapter/env.m" \
    "$ADAPTER_SOURCE/src/adapter/get.m" \
    "$ADAPTER_SOURCE/src/adapter/globals.m" \
    "$ADAPTER_SOURCE/src/adapter/keys.m" \
    "$ADAPTER_SOURCE/src/adapter/now_playing.m" \
    "$ADAPTER_SOURCE/src/adapter/send.m" \
    "$ADAPTER_SOURCE/src/private/MediaRemote.m" \
    "$ADAPTER_SOURCE/src/utility/helpers.m"
codesign --force --sign - "$ADAPTER_DYLIB" >/dev/null 2>&1
APP=build/AgentNotch.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SCRATCH/release/AgentNotch" "$APP/Contents/MacOS/AgentNotch"
cp "$SCRATCH/release/agent-notch-bridge" "$APP/Contents/MacOS/agent-notch-bridge"
cp scripts/setup-integrations.sh "$APP/Contents/Resources/setup-integrations"
cp "$ADAPTER_DYLIB" "$APP/Contents/Resources/MediaRemoteAdapter.dylib"
cp "$ADAPTER_SOURCE/mediaremote-adapter.pl" "$APP/Contents/Resources/mediaremote-adapter.pl"
cp "$ADAPTER_SOURCE/LICENSE" "$APP/Contents/Resources/MediaRemoteAdapter-LICENSE"
chmod +x "$APP/Contents/Resources/setup-integrations"
chmod +x "$APP/Contents/Resources/mediaremote-adapter.pl"
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
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>AgentNotch shows today's upcoming events in the Today tab.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>AgentNotch can fall back to Apple Events for legacy media players.</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
EOF
echo "Built: $APP"
