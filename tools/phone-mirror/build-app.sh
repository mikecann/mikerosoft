#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_CONFIGURATION="${PHONE_MIRROR_BUILD_CONFIGURATION:-release}"
APP_NAME="Phone Mirror"
APP_DIR="${PHONE_MIRROR_APP_DIR:-$HOME/Applications/$APP_NAME.app}"
APP_BIN="$APP_DIR/Contents/MacOS/phone-mirror-swift"
ICON_SOURCE="$SCRIPT_DIR/icons/phone-mirror.png"
SIGNING_IDENTITY="${PHONE_MIRROR_CODESIGN_IDENTITY:-}"
SIGNING_REQUIREMENTS=()

if ! command -v swift >/dev/null 2>&1; then
  echo "ERROR: swift is not on PATH. Install Xcode or Command Line Tools first."
  exit 1
fi

echo "Building Phone Mirror ($BUILD_CONFIGURATION)..."
swift build --package-path "$SCRIPT_DIR" -c "$BUILD_CONFIGURATION"
BIN_DIR="$(swift build --package-path "$SCRIPT_DIR" -c "$BUILD_CONFIGURATION" --show-bin-path)"
BINARY="$BIN_DIR/phone-mirror-swift"

if [[ ! -x "$BINARY" ]]; then
  echo "ERROR: built binary not found at $BINARY"
  exit 1
fi

echo "Staging $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_BIN"
cp "$SCRIPT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$SCRIPT_DIR/agent.sh" "$APP_DIR/Contents/Resources/agent.sh"
chmod +x "$APP_BIN" "$APP_DIR/Contents/Resources/agent.sh"

if [[ -f "$ICON_SOURCE" ]]; then
  ICONSET="$(mktemp -d)/phone-mirror.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/phone-mirror.icns"
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
  # hash. That changes after every build and makes macOS TCC forget Camera
  # permission. Keep a stable local requirement when no Apple Development
  # certificate is available.
  SIGNING_REQUIREMENTS=(--requirements "=designated => identifier \"$BUNDLE_ID\"")
fi

# The ${array[@]+...} form keeps bash 3.2 happy under `set -u` when the array is empty.
codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" \
  ${SIGNING_REQUIREMENTS[@]+"${SIGNING_REQUIREMENTS[@]}"} "$APP_DIR" >/dev/null

echo "Built $APP_DIR"
