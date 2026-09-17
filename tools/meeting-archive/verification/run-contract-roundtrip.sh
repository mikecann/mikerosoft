#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/meeting-archive-contract.XXXXXX")"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
export CLANG_MODULE_CACHE_PATH="$FIXTURE_ROOT/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$FIXTURE_ROOT/archive"

swiftc \
  "$TOOL_DIR/Sources/MeetingArchiveCore/ModelCodec.swift" \
  "$TOOL_DIR/Sources/MeetingArchiveCore/Models.swift" \
  "$TOOL_DIR/Sources/MeetingArchiveCore/Manifest.swift" \
  "$SCRIPT_DIR/ContractRoundTrip.swift" \
  -o "$FIXTURE_ROOT/contract-roundtrip"

MANIFEST_SHA256="$($FIXTURE_ROOT/contract-roundtrip emit "$FIXTURE_ROOT/incoming")"
PYTHONPATH="$TOOL_DIR/worker" python3 -m meeting_archive_worker accept \
  --incoming "$FIXTURE_ROOT/incoming" \
  --archive-root "$FIXTURE_ROOT/archive" \
  --db "$FIXTURE_ROOT/worker.sqlite" \
  --manifest-sha256 "$MANIFEST_SHA256" \
  > "$FIXTURE_ROOT/acknowledgement.json"

"$FIXTURE_ROOT/contract-roundtrip" validate \
  "$FIXTURE_ROOT/incoming" \
  "$FIXTURE_ROOT/acknowledgement.json"

PYTHONPATH="$TOOL_DIR/worker" python3 -m meeting_archive_worker status \
  --db "$FIXTURE_ROOT/worker.sqlite"
