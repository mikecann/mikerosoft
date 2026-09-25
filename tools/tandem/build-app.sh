#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_CONFIGURATION="${TANDEM_BUILD_CONFIGURATION:-release}"
APP_NAME="Tandem"
APP_DIR="${TANDEM_APP_DIR:-$HOME/Applications/$APP_NAME.app}"
APP_BIN="$APP_DIR/Contents/MacOS/tandem-app"
CLI_BIN="$APP_DIR/Contents/MacOS/tandem"
ICON_SOURCE="$SCRIPT_DIR/icons/tandem.png"
SIGNING_IDENTITY="${TANDEM_CODESIGN_IDENTITY:-}"
SIGNING_REQUIREMENTS=()

if ! command -v swift >/dev/null 2>&1; then
  echo "ERROR: swift is not on PATH. Install Xcode or Command Line Tools first."
  exit 1
fi

echo "Building Tandem ($BUILD_CONFIGURATION)..."
swift build --package-path "$SCRIPT_DIR" -c "$BUILD_CONFIGURATION"
BIN_DIR="$(swift build --package-path "$SCRIPT_DIR" -c "$BUILD_CONFIGURATION" --show-bin-path)"

for binary in tandem-app tandem; do
  if [[ ! -x "$BIN_DIR/$binary" ]]; then
    echo "ERROR: built binary not found at $BIN_DIR/$binary"
    exit 1
  fi
done

echo "Staging $APP_DIR..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/tandem-app" "$APP_BIN"
cp "$BIN_DIR/tandem" "$CLI_BIN"
cp "$SCRIPT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
# SwiftPM resource bundles (keymaps, packs) sit next to the binaries.
for bundle in "$BIN_DIR"/*.bundle; do
  [[ -e "$bundle" ]] || continue
  # Test fixtures are bundles too; they don't belong in the app.
  [[ "$(basename "$bundle")" == *Tests.bundle ]] && continue
  cp -R "$bundle" "$APP_DIR/Contents/Resources/"
done
chmod +x "$APP_BIN" "$CLI_BIN"

if [[ -f "$ICON_SOURCE" ]]; then
  ICONSET="$(mktemp -d)/tandem.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/tandem.icns"
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
  # Keep a stable designated requirement for ad-hoc signatures so macOS
  # privacy permissions survive rebuilds (see tools/record-it/build-app.sh).
  SIGNING_REQUIREMENTS=(--requirements "=designated => identifier \"$BUNDLE_ID\"")
fi

codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" \
  --identifier "com.mikerosoft.tandem.cli" "$CLI_BIN" >/dev/null
codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" \
  ${SIGNING_REQUIREMENTS[@]+"${SIGNING_REQUIREMENTS[@]}"} "$APP_DIR" >/dev/null

echo "Built $APP_DIR"
