#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/meeting-follow-up.XXXXXX")"
trap 'rm -rf "$BUILD_ROOT"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
swiftc "$SCRIPT_DIR/../Sources/MeetingArchiveApp/MeetingFollowUp.swift" \
  "$SCRIPT_DIR/MeetingFollowUpScenarios.swift" -o "$BUILD_ROOT/scenarios"
"$BUILD_ROOT/scenarios"
