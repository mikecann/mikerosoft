#!/usr/bin/env bash

set -euo pipefail

APP_DIR="${VIDEO_HQ_APP_DIR:-$HOME/Applications/Video HQ.app}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -d "$APP_DIR" ]] || fail "app bundle is missing at $APP_DIR"
[[ -x "$APP_DIR/Contents/MacOS/video-hq" ]] || fail "app executable is missing"

BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$APP_DIR/Contents/Info.plist")"
[[ "$BUNDLE_ID" == "com.mikerosoft.video-hq" ]] || fail "unexpected bundle identifier: $BUNDLE_ID"

ROUGH_CUT_ROOT="$(plutil -extract VideoHQFilmoraAutomationRoot raw "$APP_DIR/Contents/Info.plist")"
ROUGH_CUT_PYTHON="$(plutil -extract VideoHQRoughCutPython raw "$APP_DIR/Contents/Info.plist")"
[[ -n "$ROUGH_CUT_ROOT" ]] || fail "Filmora automation root is missing from Info.plist"
[[ -n "$ROUGH_CUT_PYTHON" ]] || fail "rough-cut Python is missing from Info.plist"

# Spotlight treats a bundle more reliably as an application when its importer has
# recorded the executable architecture, not merely the generic .app content type.
ARCHITECTURES="$(mdls -raw -name kMDItemExecutableArchitectures "$APP_DIR")"
[[ "$ARCHITECTURES" == *arm64* ]] || fail "Spotlight metadata has no arm64 executable architecture"

SPOTLIGHT_MATCHES="$(mdfind 'kMDItemCFBundleIdentifier == "com.mikerosoft.video-hq"')"
[[ "$SPOTLIGHT_MATCHES" == *"$APP_DIR"* ]] || fail "app is missing from the Spotlight index"

LAUNCH_SERVICES_MATCHES="$($LSREGISTER -dump 2>/dev/null | grep -F "$APP_DIR" || true)"
[[ -n "$LAUNCH_SERVICES_MATCHES" ]] || fail "app is missing from Launch Services"

echo "PASS: Video HQ is installed as a Spotlight-discoverable macOS app"
