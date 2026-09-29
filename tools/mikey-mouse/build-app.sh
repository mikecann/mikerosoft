#!/usr/bin/env bash
# Build, stage, and sign ~/Applications/Mikey Mouse.app.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_CONFIGURATION="${MIKEY_MOUSE_BUILD_CONFIGURATION:-release}"
APP_DIR="${MIKEY_MOUSE_APP_DIR:-$HOME/Applications/Mikey Mouse.app}"
APP_BIN="$APP_DIR/Contents/MacOS/mikey-mouse"
SIGNING_IDENTITY="${MIKEY_MOUSE_CODESIGN_IDENTITY:-}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if ! command -v swift >/dev/null 2>&1; then
  echo "ERROR: swift is not on PATH."
  echo "Install Xcode or Command Line Tools first."
  exit 1
fi

echo "Building Mikey Mouse ($BUILD_CONFIGURATION)..."
swift build --package-path "$SCRIPT_DIR" -c "$BUILD_CONFIGURATION"
BIN_DIR="$(swift build --package-path "$SCRIPT_DIR" -c "$BUILD_CONFIGURATION" --show-bin-path)"
BINARY="$BIN_DIR/mikey-mouse"

if [[ ! -x "$BINARY" ]]; then
  echo "ERROR: built binary not found at $BINARY"
  exit 1
fi

echo "Staging Mikey Mouse.app..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_BIN"
chmod +x "$APP_BIN"
cp "$SCRIPT_DIR/icons/mikey-mouse.png" "$APP_DIR/Contents/Resources/mikey-mouse.png"

cat >"$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>mikey-mouse</string>
    <key>CFBundleIdentifier</key>
    <string>com.mikerosoft.mikey-mouse</string>
    <key>CFBundleName</key>
    <string>Mikey Mouse</string>
    <key>CFBundleDisplayName</key>
    <string>Mikey Mouse</string>
    <key>CFBundleIconFile</key>
    <string>mikey-mouse.png</string>
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
  SIGNING_IDENTITY="$({
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
      | head -n 1
  } || true)"
fi
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
SIGNING_REQUIREMENTS=()
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  # An ad-hoc signature's default requirement is the binary hash, which
  # changes every build and makes macOS forget the Accessibility grant.
  # Pin it to the bundle identifier instead.
  SIGNING_REQUIREMENTS=(--requirements '=designated => identifier "com.mikerosoft.mikey-mouse"')
fi
# The ${array[@]+...} form keeps bash 3.2 happy under `set -u` when the array is empty.
codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" \
  ${SIGNING_REQUIREMENTS[@]+"${SIGNING_REQUIREMENTS[@]}"} "$APP_DIR"

if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "Built app: $APP_DIR"
