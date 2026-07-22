#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_CONFIGURATION="${RECORD_IT_BUILD_CONFIGURATION:-release}"
APP_NAME="Record It"
APP_DIR="${RECORD_IT_APP_DIR:-$HOME/Applications/$APP_NAME.app}"
APP_BIN="$APP_DIR/Contents/MacOS/record-it-swift"
ICON_SOURCE="$SCRIPT_DIR/icons/record-it.png"
SIGNING_IDENTITY="${RECORD_IT_CODESIGN_IDENTITY:-}"
SIGNING_REQUIREMENTS=()

if ! command -v swift >/dev/null 2>&1; then
  echo "ERROR: swift is not on PATH. Install Xcode or Command Line Tools first."
  exit 1
fi

echo "Building Record It ($BUILD_CONFIGURATION)..."
swift build --package-path "$SCRIPT_DIR" -c "$BUILD_CONFIGURATION"
BIN_DIR="$(swift build --package-path "$SCRIPT_DIR" -c "$BUILD_CONFIGURATION" --show-bin-path)"
BINARY="$BIN_DIR/record-it-swift"

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
  ICONSET="$(mktemp -d)/record-it.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/record-it.icns"
  rm -rf "$(dirname "$ICONSET")"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$({
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
      | head -n 1
  } || true)"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="-"
fi

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")"
  # The default designated requirement for an ad-hoc signature is its binary
  # hash. That changes after every build and makes macOS TCC forget Screen
  # Recording, Camera, and Microphone permission. Keep a stable local
  # requirement when no Apple Development certificate is available.
  SIGNING_REQUIREMENTS=(--requirements "=designated => identifier \"$BUNDLE_ID\"")
fi

codesign --force --deep --timestamp=none --sign "$SIGNING_IDENTITY" \
  "${SIGNING_REQUIREMENTS[@]}" "$APP_DIR" >/dev/null

echo "Built $APP_DIR"
