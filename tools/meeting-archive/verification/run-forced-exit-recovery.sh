#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/meeting-archive-crash.XXXXXX")"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export CLANG_MODULE_CACHE_PATH="$FIXTURE_ROOT/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$FIXTURE_ROOT/output"

swiftc \
  "$TOOL_DIR/Sources/MeetingArchiveApp/CaptureTimeline.swift" \
  "$TOOL_DIR/Sources/MeetingArchiveApp/NativeRecording.swift" \
  "$SCRIPT_DIR/ForcedExitWriter.swift" \
  -o "$FIXTURE_ROOT/forced-exit-writer"

"$FIXTURE_ROOT/forced-exit-writer" write-crash "$FIXTURE_ROOT/output"
"$FIXTURE_ROOT/forced-exit-writer" inspect "$FIXTURE_ROOT/output"

FFMPEG="$(command -v ffmpeg)"
"$FFMPEG" -hide_banner -loglevel error \
  -i "$FIXTURE_ROOT/output/meeting-view.mov" \
  -i "$FIXTURE_ROOT/output/microphone.m4a" \
  -i "$FIXTURE_ROOT/output/incoming.m4a" \
  -filter_complex '[1:a:0][2:a:0]amix=inputs=2:duration=longest[a]' \
  -map 0:v:0 -map '[a]' -c:v copy -c:a aac \
  "$FIXTURE_ROOT/recovered.mp4"
test -s "$FIXTURE_ROOT/recovered.mp4"
echo "forced-exit fragments remuxed successfully"
