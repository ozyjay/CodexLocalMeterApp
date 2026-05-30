#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Codex Local Meter"
BUILD_CONFIG="${BUILD_CONFIG:-release}"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
APP_ICON_PNG="$ROOT_DIR/Sources/CodexLocalMeterApp/Resources/app-icon.png"
APP_ICON_ICNS="$RESOURCES_DIR/AppIcon.icns"

cd "$ROOT_DIR"
swift build -c "$BUILD_CONFIG" --product CodexLocalMeterApp

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$ROOT_DIR/.build/$BUILD_CONFIG/CodexLocalMeterApp" "$MACOS_DIR/Codex Local Meter"
mv "$MACOS_DIR/Codex Local Meter" "$MACOS_DIR/CodexLocalMeter"
cp "$ROOT_DIR/Sources/CodexLocalMeterApp/Resources/status-icon.svg" "$RESOURCES_DIR/status-icon.svg"

ICONSET_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-local-meter-iconset.XXXXXX")"
trap 'rm -rf "$ICONSET_DIR"' EXIT
mkdir -p "$ICONSET_DIR/AppIcon.iconset"
sips -z 16 16 "$APP_ICON_PNG" --out "$ICONSET_DIR/AppIcon.iconset/icon_16x16.png" >/dev/null
sips -z 32 32 "$APP_ICON_PNG" --out "$ICONSET_DIR/AppIcon.iconset/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$APP_ICON_PNG" --out "$ICONSET_DIR/AppIcon.iconset/icon_32x32.png" >/dev/null
sips -z 64 64 "$APP_ICON_PNG" --out "$ICONSET_DIR/AppIcon.iconset/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$APP_ICON_PNG" --out "$ICONSET_DIR/AppIcon.iconset/icon_128x128.png" >/dev/null
sips -z 256 256 "$APP_ICON_PNG" --out "$ICONSET_DIR/AppIcon.iconset/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$APP_ICON_PNG" --out "$ICONSET_DIR/AppIcon.iconset/icon_256x256.png" >/dev/null
sips -z 512 512 "$APP_ICON_PNG" --out "$ICONSET_DIR/AppIcon.iconset/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$APP_ICON_PNG" --out "$ICONSET_DIR/AppIcon.iconset/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$APP_ICON_PNG" --out "$ICONSET_DIR/AppIcon.iconset/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET_DIR/AppIcon.iconset" -o "$APP_ICON_ICNS"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>CodexLocalMeter</string>
    <key>CFBundleIdentifier</key>
    <string>local.codex-meter.CodexLocalMeter</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Codex Local Meter</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Local-only Codex usage meter.</string>
</dict>
</plist>
PLIST

echo "Packaged: $APP_DIR"
