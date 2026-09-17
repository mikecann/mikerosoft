#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${MEETING_ARCHIVE_WORKER_LAUNCHER_BUILD_DIR:-${SCRIPT_DIR}/.build}"
MODULE_CACHE="${CLANG_MODULE_CACHE_PATH:-${BUILD_ROOT}/module-cache}"
INFO_PLIST="${SCRIPT_DIR}/Resources/Info.plist"

mkdir -p "${BUILD_ROOT}" "${MODULE_CACHE}"
swiftc \
    -target arm64-apple-macos15.0 \
    -module-cache-path "${MODULE_CACHE}" \
    "${SCRIPT_DIR}/Sources/LauncherConfiguration.swift" \
    "${SCRIPT_DIR}/Tests/LauncherConfigurationTests.swift" \
    -o "${BUILD_ROOT}/launcher-configuration-tests"
"${BUILD_ROOT}/launcher-configuration-tests"

plutil -lint "${INFO_PLIST}" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${INFO_PLIST}")" == \
    "meeting-archive-worker" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${INFO_PLIST}")" == \
    "com.mikerosoft.meeting-archive-worker" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${INFO_PLIST}")" == "15.0" ]]
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :NSRemovableVolumesUsageDescription' "${INFO_PLIST}")" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "${INFO_PLIST}")" == "true" ]]
echo "Meeting Archive Worker Info.plist contract tests passed"
