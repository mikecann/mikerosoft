#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="${MEETING_ARCHIVE_UI_HARNESS_BUILD_DIR:-${TOOL_DIR}/.build/follow-up-ui-harness}"
MODULE_CACHE="${CLANG_MODULE_CACHE_PATH:-${BUILD_ROOT}/module-cache}"
APP_PATH="${MEETING_ARCHIVE_UI_HARNESS_APP:-/private/tmp/Meeting Archive UI Verification.app}"
SOURCE_DATABASE="${MEETING_ARCHIVE_SOURCE_DB:-${HOME}/Library/Application Support/Meeting Archive/meetings.sqlite}"
BUNDLE_ID="com.mikerosoft.meeting-archive-ui-verification"
MODE="${1:---build}"

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
mkdir -p "$BUILD_ROOT" "$MODULE_CACHE"

build_harness() {
  local staging="${APP_PATH}.staging"
  rm -rf "$staging"
  mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Frameworks"

  swiftc -j 2 -target arm64-apple-macos15.0 \
    -emit-library -emit-module -module-name MeetingArchiveCore \
    -I "$TOOL_DIR/Sources/MeetingArchiveCore/CSQLite" \
    "$TOOL_DIR/Sources/MeetingArchiveCore/ModelCodec.swift" \
    "$TOOL_DIR/Sources/MeetingArchiveCore/Models.swift" \
    "$TOOL_DIR/Sources/MeetingArchiveCore/Manifest.swift" \
    "$TOOL_DIR/Sources/MeetingArchiveCore/CaptureStateMachine.swift" \
    "$TOOL_DIR/Sources/MeetingArchiveCore/SQLiteMeetingStore.swift" \
    -Xlinker -install_name -Xlinker @rpath/libMeetingArchiveCore.dylib \
    -lsqlite3 \
    -emit-module-path "$BUILD_ROOT/MeetingArchiveCore.swiftmodule" \
    -o "$BUILD_ROOT/libMeetingArchiveCore.dylib"

  local -a app_sources=()
  while IFS= read -r source; do app_sources+=("$source"); done < <(
    find "$TOOL_DIR/Sources/MeetingArchiveApp" -maxdepth 1 -name '*.swift' ! -name 'StartupCommand.swift' -print | sort
  )
  swiftc -j 2 -target arm64-apple-macos15.0 -parse-as-library \
    -I "$BUILD_ROOT" -L "$BUILD_ROOT" -lMeetingArchiveCore \
    -I "$TOOL_DIR/Sources/MeetingArchiveCore/CSQLite" -lsqlite3 \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    "${app_sources[@]}" "$SCRIPT_DIR/FollowUpUIHarness.swift" \
    -o "$staging/Contents/MacOS/follow-up-ui-harness"
  cp "$BUILD_ROOT/libMeetingArchiveCore.dylib" "$staging/Contents/Frameworks/"

  cat >"$staging/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>follow-up-ui-harness</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>Meeting Archive UI Verification</string>
  <key>CFBundleDisplayName</key><string>Meeting Archive UI Verification</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

  codesign --force --timestamp=none --sign - "$staging/Contents/Frameworks/libMeetingArchiveCore.dylib"
  codesign --force --timestamp=none --sign - \
    --requirements "=designated => identifier \"${BUNDLE_ID}\"" "$staging"
  codesign --verify --deep --strict "$staging"
  if [[ -e "$APP_PATH" ]]; then
    existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$existing_id" == "$BUNDLE_ID" ]] || {
      echo "Refusing to replace an unrelated app at $APP_PATH" >&2
      exit 1
    }
    rm -rf "$APP_PATH"
  fi
  mv "$staging" "$APP_PATH"
  echo "Built $APP_PATH"
}

prepare_isolated_data() {
  [[ -f "$SOURCE_DATABASE" && ! -L "$SOURCE_DATABASE" ]] || {
    echo "Production database is missing or unsafe: $SOURCE_DATABASE" >&2
    exit 1
  }
  local data_root
  data_root="$(mktemp -d /private/tmp/meeting-archive-ui-verification.XXXXXX)"
  chmod 700 "$data_root"
  /usr/bin/python3 - "$SOURCE_DATABASE" "$data_root/meetings.sqlite" <<'PY'
import sqlite3
import sys
from contextlib import closing
from urllib.parse import quote

source, destination = sys.argv[1:]
source_uri = "file:" + quote(source, safe="/") + "?mode=ro"
with closing(sqlite3.connect(source_uri, uri=True)) as source_connection:
    with closing(sqlite3.connect(destination)) as destination_connection:
        source_connection.backup(destination_connection)
        destination_connection.commit()
PY
  chmod 600 "$data_root/meetings.sqlite"
  printf '%s\n' "$data_root"
}

case "$MODE" in
  --build)
    build_harness
    echo "Prepare isolated data for CUA with: $0 --prepare"
    ;;
  --prepare)
    build_harness
    data_root="$(prepare_isolated_data)"
    mkdir -p "$APP_PATH/Contents/Resources"
    printf '%s\n' "$data_root" >"$APP_PATH/Contents/Resources/data-root.txt"
    chmod 600 "$APP_PATH/Contents/Resources/data-root.txt"
    /usr/libexec/PlistBuddy -c 'Delete :LSEnvironment' "$APP_PATH/Contents/Info.plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c 'Add :LSEnvironment dict' "$APP_PATH/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :LSEnvironment:MEETING_ARCHIVE_DATA_DIR string $data_root" \
      "$APP_PATH/Contents/Info.plist"
    codesign --force --timestamp=none --sign - \
      --requirements "=designated => identifier \"${BUNDLE_ID}\"" "$APP_PATH"
    codesign --verify --deep --strict "$APP_PATH"
    echo "Prepared $APP_PATH"
    echo "Isolated data root: $data_root"
    echo "Launch the app bundle through CUA; do not execute the binary directly."
    ;;
  *)
    echo "Usage: $0 [--build|--prepare]" >&2
    exit 64
    ;;
esac
