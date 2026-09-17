#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD_DIR="$SCRIPT_DIR/.build"
CLT_DIR=/Library/Developer/CommandLineTools
SWIFTC="$CLT_DIR/usr/bin/swiftc"
SDKROOT=${SDKROOT:-$CLT_DIR/SDKs/MacOSX15.4.sdk}

mkdir -p "$BUILD_DIR/module-cache"

DEVELOPER_DIR="$CLT_DIR" "$SWIFTC" \
  -sdk "$SDKROOT" \
  -target arm64-apple-macosx14.0 \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -parse-as-library \
  "$SCRIPT_DIR/Sources/CandidateRules.swift" \
  "$SCRIPT_DIR/Tests/CandidateRulesTests.swift" \
  -o "$BUILD_DIR/candidate-rules-tests"

"$BUILD_DIR/candidate-rules-tests"
