#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/meeting-archive-state.XXXXXX")"
trap 'rm -rf "$BUILD_ROOT"' EXIT

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

swiftc \
  "$TOOL_DIR/Sources/MeetingArchiveCore/ModelCodec.swift" \
  "$TOOL_DIR/Sources/MeetingArchiveCore/Models.swift" \
  "$TOOL_DIR/Sources/MeetingArchiveCore/Manifest.swift" \
  "$TOOL_DIR/Sources/MeetingArchiveCore/CaptureStateMachine.swift" \
  "$SCRIPT_DIR/StateMachineScenarios.swift" \
  -o "$BUILD_ROOT/state-machine-scenarios"

"$BUILD_ROOT/state-machine-scenarios"
