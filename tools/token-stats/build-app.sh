#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_CONFIGURATION="${TOKEN_STATS_BUILD_CONFIGURATION:-release}"
APP_NAME="Token Stats"
APP_DIR="${TOKEN_STATS_APP_DIR:-$HOME/Applications/$APP_NAME.app}"
APP_BIN="$APP_DIR/Contents/MacOS/token-stats-swift"
ICON_SOURCE="$SCRIPT_DIR/icons/token-stats.png"

if ! command -v swift >/dev/null 2>&1; then
  echo "ERROR: swift is not on PATH. Install Xcode or Command Line Tools first."
  exit 1
fi

echo "Building Token Stats ($BUILD_CONFIGURATION)..."
swift build --package-path "$SCRIPT_DIR" -c "$BUILD_CONFIGURATION"
BIN_DIR="$(swift build --package-path "$SCRIPT_DIR" -c "$BUILD_CONFIGURATION" --show-bin-path)"
BINARY="$BIN_DIR/token-stats-swift"

if [[ ! -x "$BINARY" ]]; then
  echo "ERROR: built binary not found at $BINARY"
  exit 1
fi

echo "Staging $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_BIN"
cp "$SCRIPT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$APP_BIN"

if [[ -f "$ICON_SOURCE" ]]; then
  ICONSET="$(mktemp -d)/token-stats.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/token-stats.icns"
  rm -rf "$(dirname "$ICONSET")"
fi

codesign --force --deep --timestamp=none --sign - "$APP_DIR" >/dev/null
echo "Built $APP_DIR"
