#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 LOCAL_BUNDLE HOST VALIDATION_ROOT" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/meeting-archive-live-transfer.XXXXXX")"
trap 'rm -rf "$BUILD_ROOT"' EXIT

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

swiftc -emit-library -emit-module -module-name MeetingArchiveCore \
  "$TOOL_DIR/Sources/MeetingArchiveCore/ModelCodec.swift" \
  "$TOOL_DIR/Sources/MeetingArchiveCore/Models.swift" \
  "$TOOL_DIR/Sources/MeetingArchiveCore/Manifest.swift" \
  -emit-module-path "$BUILD_ROOT/MeetingArchiveCore.swiftmodule" \
  -o "$BUILD_ROOT/libMeetingArchiveCore.dylib"

swiftc \
  -I "$BUILD_ROOT" -L "$BUILD_ROOT" -lMeetingArchiveCore \
  "$TOOL_DIR/Sources/MeetingArchiveApp/ArchiveTransfer.swift" \
  "$SCRIPT_DIR/LiveTransferDriver.swift" \
  -o "$BUILD_ROOT/live-transfer"

DYLD_LIBRARY_PATH="$BUILD_ROOT" "$BUILD_ROOT/live-transfer" "$1" "$2" "$3"
