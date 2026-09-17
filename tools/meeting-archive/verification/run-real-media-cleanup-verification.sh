#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE="${1:-/private/tmp/meeting-archive-e2e}"

if [[ ! -d "$FIXTURE" ]]; then
  echo "Real-media fixture is missing: $FIXTURE" >&2
  exit 1
fi

RUN_ROOT="$(mktemp -d /private/tmp/meeting-archive-cleanup-real.XXXXXX)"
SOURCE_COPY="$RUN_ROOT/source"
INDEX_COPY="$RUN_ROOT/index"
BUILD_ROOT="$RUN_ROOT/build"
trap '/bin/rm -rf "$RUN_ROOT"' EXIT

mkdir -p "$SOURCE_COPY" "$BUILD_ROOT"
/bin/cp -R "$FIXTURE/." "$SOURCE_COPY"

snapshot_fixture() {
  find "$FIXTURE" -type f -exec shasum -a 256 {} \; \
    | sed "s|  $FIXTURE/|  |" \
    | sort
}

snapshot_fixture > "$RUN_ROOT/original-before.sha256"

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

swiftc -j 2 -emit-library -emit-module -module-name MeetingArchiveCore \
  "$TOOL_DIR/Sources/MeetingArchiveCore/ModelCodec.swift" \
  "$TOOL_DIR/Sources/MeetingArchiveCore/Models.swift" \
  "$TOOL_DIR/Sources/MeetingArchiveCore/Manifest.swift" \
  -emit-module-path "$BUILD_ROOT/MeetingArchiveCore.swiftmodule" \
  -o "$BUILD_ROOT/libMeetingArchiveCore.dylib"

swiftc -j 2 -I "$BUILD_ROOT" -L "$BUILD_ROOT" -lMeetingArchiveCore \
  "$TOOL_DIR/Sources/MeetingArchiveApp/CaptureTimeline.swift" \
  "$TOOL_DIR/Sources/MeetingArchiveApp/SpoolBundle.swift" \
  "$TOOL_DIR/Sources/MeetingArchiveApp/ArchiveTransfer.swift" \
  "$TOOL_DIR/Sources/MeetingArchiveApp/ArchiveCleanup.swift" \
  "$SCRIPT_DIR/RealMediaCleanupVerification.swift" \
  -o "$BUILD_ROOT/real-media-cleanup"

DYLD_LIBRARY_PATH="$BUILD_ROOT" "$BUILD_ROOT/real-media-cleanup" "$SOURCE_COPY" "$INDEX_COPY"

snapshot_fixture > "$RUN_ROOT/original-after.sha256"
cmp "$RUN_ROOT/original-before.sha256" "$RUN_ROOT/original-after.sha256"
echo "Original fixture remained byte-for-byte unchanged: $FIXTURE"
