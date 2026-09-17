#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/meeting-speaker-review.XXXXXX")"
trap 'rm -rf "$BUILD_ROOT"' EXIT

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
: "${CLANG_MODULE_CACHE_PATH:=$BUILD_ROOT/module-cache}"
export CLANG_MODULE_CACHE_PATH
mkdir -p "$CLANG_MODULE_CACHE_PATH"

swiftc -j 2 -emit-library -emit-module -module-name MeetingArchiveCore \
  "$TOOL_DIR/Sources/MeetingArchiveCore/ModelCodec.swift" \
  "$TOOL_DIR/Sources/MeetingArchiveCore/Models.swift" \
  "$TOOL_DIR/Sources/MeetingArchiveCore/Manifest.swift" \
  -emit-module-path "$BUILD_ROOT/MeetingArchiveCore.swiftmodule" \
  -o "$BUILD_ROOT/libMeetingArchiveCore.dylib"

swiftc -j 2 -I "$BUILD_ROOT" -L "$BUILD_ROOT" -lMeetingArchiveCore \
  "$TOOL_DIR/Sources/MeetingArchiveApp/ArchiveTransfer.swift" \
  "$TOOL_DIR/Sources/MeetingArchiveApp/SpeakerReview.swift" \
  "$SCRIPT_DIR/SpeakerReviewScenarios.swift" \
  -o "$BUILD_ROOT/speaker-review-scenarios"

DYLD_LIBRARY_PATH="$BUILD_ROOT" "$BUILD_ROOT/speaker-review-scenarios"
