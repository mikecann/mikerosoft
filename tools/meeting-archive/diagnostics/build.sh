#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD_DIR="$SCRIPT_DIR/.build"
CLT_DIR=/Library/Developer/CommandLineTools
SWIFTC="$CLT_DIR/usr/bin/swiftc"

# The full Xcode install on this machine currently has an unaccepted licence.
# Use the separately installed Command Line Tools and keep the module cache local.
SDKROOT=${SDKROOT:-$CLT_DIR/SDKs/MacOSX15.4.sdk}

if [ ! -x "$SWIFTC" ] || [ ! -d "$SDKROOT" ]; then
  echo "A usable Command Line Tools Swift compiler and macOS SDK are required." >&2
  exit 1
fi

mkdir -p "$BUILD_DIR/module-cache"

DEVELOPER_DIR="$CLT_DIR" "$SWIFTC" \
  -sdk "$SDKROOT" \
  -target arm64-apple-macosx14.0 \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -parse-as-library \
  "$SCRIPT_DIR/Sources/CandidateRules.swift" \
  "$SCRIPT_DIR/Sources/Diagnostic.swift" \
  -framework AVFoundation \
  -framework CoreGraphics \
  -framework CoreMediaIO \
  -framework ScreenCaptureKit \
  -o "$BUILD_DIR/meeting-archive-diagnostic"

echo "$BUILD_DIR/meeting-archive-diagnostic"
