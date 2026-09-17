#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="${1:?Pass a directory containing review.json and meeting.mp4}"
APP="${2:-/private/tmp/Meeting Archive Speaker Suggestions.app}"
[[ -f "$FIXTURES/review.json" && -f "$FIXTURES/meeting.mp4" ]] || exit 2
[[ ! -e "$APP" ]] || { echo "App already exists: $APP" >&2; exit 2; }
BUILD="$(mktemp -d /private/tmp/meeting-speaker-suggestions.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export CLANG_MODULE_CACHE_PATH="$BUILD/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
swiftc -j 2 -emit-library -emit-module -module-name MeetingArchiveCore \
  "$TOOL_DIR/Sources/MeetingArchiveCore/ModelCodec.swift" \
  "$TOOL_DIR/Sources/MeetingArchiveCore/Models.swift" \
  "$TOOL_DIR/Sources/MeetingArchiveCore/Manifest.swift" \
  -Xlinker -install_name -Xlinker @rpath/libMeetingArchiveCore.dylib \
  -emit-module-path "$BUILD/MeetingArchiveCore.swiftmodule" \
  -o "$APP/Contents/Frameworks/libMeetingArchiveCore.dylib"
swiftc -j 2 -I "$BUILD" -L "$APP/Contents/Frameworks" -lMeetingArchiveCore \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "$TOOL_DIR/Sources/MeetingArchiveApp/ArchiveTransfer.swift" \
  "$TOOL_DIR/Sources/MeetingArchiveApp/SpeakerReview.swift" \
  "$SCRIPT_DIR/SpeakerSuggestionsUIHarness.swift" -o "$APP/Contents/MacOS/speaker-suggestions"
cp "$FIXTURES/review.json" "$FIXTURES/meeting.mp4" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>speaker-suggestions</string>
<key>CFBundleIdentifier</key><string>com.mikerosoft.meeting-archive-speaker-verification</string>
<key>CFBundleName</key><string>Meeting Archive Speaker Suggestions</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
codesign --force --timestamp=none --sign - "$APP/Contents/Frameworks/libMeetingArchiveCore.dylib"
codesign --force --timestamp=none --sign - "$APP"
echo "Prepared $APP. Launch through CUA."
