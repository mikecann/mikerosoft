#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/meeting-label-ocr.XXXXXX")"
trap 'rm -rf "$BUILD_ROOT"' EXIT

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
: "${CLANG_MODULE_CACHE_PATH:=$BUILD_ROOT/module-cache}"
export CLANG_MODULE_CACHE_PATH
mkdir -p "$CLANG_MODULE_CACHE_PATH"

swiftc -O -whole-module-optimization -target arm64-apple-macos15.0 \
  -framework Vision -framework ImageIO \
  "$SCRIPT_DIR/MeetingLabelOCR.swift" \
  -o "$BUILD_ROOT/meeting-label-ocr"
chmod 700 "$BUILD_ROOT/meeting-label-ocr"
mv -f "$BUILD_ROOT/meeting-label-ocr" "$SCRIPT_DIR/meeting-label-ocr"
echo "Built $SCRIPT_DIR/meeting-label-ocr"
