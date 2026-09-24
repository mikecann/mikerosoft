#!/usr/bin/env bash
# Build, stage, and sign ~/Applications/Telemprompit.app.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_CONFIGURATION="${TELEMPROMPIT_BUILD_CONFIGURATION:-release}"
APP_NAME="Telemprompit"
APP_DIR="${TELEMPROMPIT_APP_DIR:-$HOME/Applications/$APP_NAME.app}"
APP_BIN="$APP_DIR/Contents/MacOS/telemprompit"
ICON_SOURCE="$SCRIPT_DIR/icons/telemprompit.png"
SIGNING_IDENTITY="${TELEMPROMPIT_CODESIGN_IDENTITY:-}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

if ! command -v swift >/dev/null 2>&1; then
  echo "ERROR: swift is not on PATH. Install Xcode or Command Line Tools first." >&2
  exit 1
fi

echo "Building Telemprompit ($BUILD_CONFIGURATION)..."
swift build --package-path "$SCRIPT_DIR" -c "$BUILD_CONFIGURATION"
BIN_DIR="$(swift build --package-path "$SCRIPT_DIR" -c "$BUILD_CONFIGURATION" --show-bin-path)"
BINARY="$BIN_DIR/telemprompit"

if [[ ! -x "$BINARY" ]]; then
  echo "ERROR: built binary not found at $BINARY" >&2
  exit 1
fi

bash "$SCRIPT_DIR/kill.sh" >/dev/null || true

echo "Staging $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_BIN"
cp "$SCRIPT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$APP_BIN"

if [[ -f "$ICON_SOURCE" ]]; then
  ICONSET="$(mktemp -d)/telemprompit.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/telemprompit.icns"
  rm -rf "$(dirname "$ICONSET")"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$({
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
      | head -n 1
  } || true)"
fi
SIGNING_REQUIREMENTS=()
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="-"
  # An ad-hoc signature's default requirement is the binary hash, which
  # changes every build and makes macOS forget the Accessibility grant used
  # by "Turn On Elgato Prompter". Pin it to the bundle identifier instead.
  SIGNING_REQUIREMENTS=(--requirements '=designated => identifier "com.mikerosoft.telemprompit"')
fi
codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" \
  "${SIGNING_REQUIREMENTS[@]+"${SIGNING_REQUIREMENTS[@]}"}" "$APP_DIR" >/dev/null

if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "Built $APP_DIR"
