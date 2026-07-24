#!/usr/bin/env bash
# Build, stage, and sign the app bundle used for Accessibility permission.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_CONFIGURATION="${LAST_WINDOW_QUITS_BUILD_CONFIGURATION:-debug}"
APP_DIR="${LAST_WINDOW_QUITS_APP_DIR:-$HOME/Applications/Last Window Quits.app}"
APP_BIN="$APP_DIR/Contents/MacOS/last-window-quits"
SIGNING_IDENTITY="${LAST_WINDOW_QUITS_CODESIGN_IDENTITY:-}"
DESIGNATED_REQUIREMENT='=designated => identifier "com.mikerosoft.last-window-quits"'

if ! command -v swift >/dev/null 2>&1; then
  echo "ERROR: swift is not on PATH."
  echo "Install Xcode or Command Line Tools first."
  exit 1
fi

echo "Building Last Window Quits ($BUILD_CONFIGURATION)..."
swift build --package-path "$SCRIPT_DIR" -c "$BUILD_CONFIGURATION"
BIN_DIR="$(swift build --package-path "$SCRIPT_DIR" -c "$BUILD_CONFIGURATION" --show-bin-path)"
BINARY="$BIN_DIR/last-window-quits"

if [[ ! -x "$BINARY" ]]; then
  echo "ERROR: built binary not found at $BINARY"
  exit 1
fi

echo "Staging Last Window Quits.app..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_BIN"
chmod +x "$APP_BIN"
cp "$SCRIPT_DIR/icons/last-window-quits.png" \
  "$APP_DIR/Contents/Resources/last-window-quits.png"

cat >"$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>last-window-quits</string>
    <key>CFBundleIdentifier</key>
    <string>com.mikerosoft.last-window-quits</string>
    <key>CFBundleName</key>
    <string>Last Window Quits</string>
    <key>CFBundleDisplayName</key>
    <string>Last Window Quits</string>
    <key>CFBundleIconFile</key>
    <string>last-window-quits.png</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
      | head -n 1
  )"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="-"
fi

# A stable designated requirement keeps the Accessibility grant valid when an
# ad-hoc signed debug build changes.
codesign --force --deep --timestamp=none \
  --sign "$SIGNING_IDENTITY" \
  --requirements "$DESIGNATED_REQUIREMENT" \
  "$APP_DIR"

echo "Built app: $APP_DIR"
