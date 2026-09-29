#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${MEETING_ARCHIVE_WORKER_LAUNCHER_BUILD_DIR:-${SCRIPT_DIR}/.build}"
MODULE_CACHE="${CLANG_MODULE_CACHE_PATH:-${BUILD_ROOT}/module-cache}"
APP_DIR="${MEETING_ARCHIVE_WORKER_APP_DIR:-${HOME}/Applications/Meeting Archive Worker.app}"
BUNDLE_ID="com.mikerosoft.meeting-archive-worker"
SIGNING_IDENTITY="${MEETING_ARCHIVE_WORKER_CODESIGN_IDENTITY:--}"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/meeting-archive-worker.XXXXXX")"
STAGING_APP="${STAGING_ROOT}/Meeting Archive Worker.app"
trap 'rm -rf "${STAGING_ROOT}"' EXIT

mkdir -p "${BUILD_ROOT}" "${MODULE_CACHE}"
"${SCRIPT_DIR}/run-tests.sh"

swiftc \
    -target arm64-apple-macos15.0 \
    -O \
    -parse-as-library \
    -module-cache-path "${MODULE_CACHE}" \
    -framework AppKit \
    "${SCRIPT_DIR}/Sources/LauncherConfiguration.swift" \
    "${SCRIPT_DIR}/Sources/main.swift" \
    -o "${BUILD_ROOT}/meeting-archive-worker"

mkdir -p "${STAGING_APP}/Contents/MacOS" "${STAGING_APP}/Contents/Resources"
cp "${BUILD_ROOT}/meeting-archive-worker" "${STAGING_APP}/Contents/MacOS/meeting-archive-worker"
cp "${SCRIPT_DIR}/Resources/Info.plist" "${STAGING_APP}/Contents/Info.plist"
chmod 755 "${STAGING_APP}/Contents/MacOS/meeting-archive-worker"

SIGNING_REQUIREMENTS=()
if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
    # A normal ad-hoc designated requirement is the binary hash. Keep the
    # local app identity stable across rebuilds so scoped volume consent does
    # not disappear whenever the executable changes.
    SIGNING_REQUIREMENTS=(--requirements "=designated => identifier \"${BUNDLE_ID}\"")
fi
# The ${array[@]+...} form keeps bash 3.2 happy under `set -u` when the array is empty.
codesign --force --timestamp=none --sign "${SIGNING_IDENTITY}" \
    ${SIGNING_REQUIREMENTS[@]+"${SIGNING_REQUIREMENTS[@]}"} "${STAGING_APP}"
codesign --verify --strict "${STAGING_APP}"
if [[ "${SIGNING_IDENTITY}" == "-" ]]; then
    requirement="$(codesign -d -r- "${STAGING_APP}" 2>&1)"
    [[ "${requirement}" == *"designated => identifier \"${BUNDLE_ID}\""* ]] || {
        echo "Signed app does not have the required stable designated requirement." >&2
        exit 1
    }
fi

mkdir -p "$(dirname "${APP_DIR}")"
rm -rf "${APP_DIR}"
mv "${STAGING_APP}" "${APP_DIR}"
echo "Built and signed ${APP_DIR}"
