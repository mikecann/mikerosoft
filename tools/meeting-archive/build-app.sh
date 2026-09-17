#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${MEETING_ARCHIVE_APP_DIR:-$HOME/Applications/Meeting Archive.app}"
CONFIGURATION="${MEETING_ARCHIVE_BUILD_CONFIGURATION:-debug}"
export CLANG_MODULE_CACHE_PATH="$SCRIPT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
swift build --package-path "$SCRIPT_DIR" --disable-sandbox -c "$CONFIGURATION"
BIN_DIR="$(swift build --package-path "$SCRIPT_DIR" --disable-sandbox -c "$CONFIGURATION" --show-bin-path)"
STAGING="${APP_DIR}.staging"
if [[ -e "$STAGING" ]]; then
  echo "Staging already exists: $STAGING. Inspect it before retrying." >&2
  exit 1
fi
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Library/LaunchAgents"
cp "$BIN_DIR/meeting-archive-app" "$STAGING/Contents/MacOS/"
cp "$SCRIPT_DIR/Resources/Info.plist" "$STAGING/Contents/Info.plist"
cp "$SCRIPT_DIR/Resources/com.mikerosoft.meeting-archive.plist" "$STAGING/Contents/Library/LaunchAgents/"
codesign --force --timestamp=none --sign "${MEETING_ARCHIVE_SIGNING_IDENTITY:--}" \
  --requirements '=designated => identifier "com.mikerosoft.meeting-archive"' "$STAGING"
codesign --verify --strict "$STAGING"
# The old app is retained until the newly signed bundle is ready.
if [[ -e "$APP_DIR" ]]; then
  BACKUP="${APP_DIR}.previous"
  if [[ -e "$BACKUP" ]]; then rm -rf "$BACKUP"; fi
  mv "$APP_DIR" "$BACKUP"
fi
mv "$STAGING" "$APP_DIR"
echo "$APP_DIR"
