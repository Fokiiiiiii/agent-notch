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
# Placed under Contents/Resources (not the bundle root) so `codesign --deep`
# can seal it; unused at runtime (String(localized:) reads Bundle.main's own
# .lproj files generated below), kept only so the raw SwiftPM resource isn't
# silently dropped.
cp -R "$SCRATCH/release/agent-notch_AgentNotch.bundle" "$APP/Contents/Resources/agent-notch_AgentNotch.bundle"
# swift build (CLT only, no Xcode/actool) just copies Localizable.xcstrings as raw JSON
# instead of compiling it, and String(localized:) in the app looks up Bundle.main's own
# Contents/Resources/<lang>.lproj -- not the nested SwiftPM resource bundle. Bridge the
# gap by emitting classic .strings files straight into the app bundle.
python3 scripts/xcstrings_to_strings.py \
    Sources/AgentNotch/Resources/Localizable.xcstrings \
    "$APP/Contents/Resources"
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
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>AgentNotch shows reminders due today alongside your calendar.</string>
    <key>NSCameraUsageDescription</key>
    <string>AgentNotch shows a live mirror in the Dashboard when you enable the Mirror widget.</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>AgentNotch reads the battery level of connected AirPods when you enable that indicator.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>AgentNotch can fall back to Apple Events for legacy media players.</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
        <string>es</string>
        <string>fr</string>
        <string>de</string>
        <string>ru</string>
        <string>ar</string>
        <string>pt</string>
        <string>hi</string>
        <string>ja</string>
        <string>ko</string>
        <string>it</string>
        <string>id</string>
        <string>vi</string>
        <string>th</string>
        <string>fil</string>
    </array>
</dict>
</plist>
EOF
# Sign the whole bundle (ad-hoc) so Info.plist is bound into the code
# signature. Without this, UNUserNotificationCenter.requestAuthorization
# fails to register the app with usernoted and native notifications never
# fire — the raw linker-signed executable + hand-assembled bundle structure
# isn't a valid signed bundle on its own.
codesign --force --deep --sign - "$APP"
# Verify by re-signing check rather than re-reading the signature immediately:
# build/ lives under the iCloud-synced ~/Documents tree, and an immediate
# `codesign -dv` re-read can observe a stale/incomplete view of what was just
# written, producing a false "not bound" warning even though signing (whose
# own exit code above already succeeded) was fine.
if ! codesign --verify --deep "$APP" 2>/dev/null; then
    echo "warning: codesign --verify failed after signing" >&2
fi
echo "Built: $APP"
