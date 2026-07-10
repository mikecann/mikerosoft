#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_DIR="$(mktemp -d)"
APP="$TEMP_DIR/Display Workspace.app"

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

if [ -n "${DISPLAY_WORKSPACE_SIGNING_IDENTITY:-}" ]; then
  SIGNING_IDENTITY="$DISPLAY_WORKSPACE_SIGNING_IDENTITY"
else
  SIGNING_IDENTITY="$({
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\([^"]*\)".*/\1/p'
  } | sed -n '1p')"
fi

if [ -z "$SIGNING_IDENTITY" ] || [ "$SIGNING_IDENTITY" = "-" ]; then
  echo "FAIL: No stable code-signing identity is available." >&2
  exit 1
fi

DISPLAY_WORKSPACE_APP="$APP" bash "$SCRIPT_DIR/build.sh" >/dev/null
BEFORE="$(codesign -d -r- "$APP" 2>&1)"

touch "$APP/Contents/Resources/signing-regression-probe"
codesign \
  --force \
  --sign "$SIGNING_IDENTITY" \
  --identifier com.mikerosoft.display-workspace \
  "$APP" >/dev/null

AFTER="$(codesign -d -r- "$APP" 2>&1)"

if [ "$BEFORE" != "$AFTER" ]; then
  echo "FAIL: Display Workspace's designated requirement changes after a rebuild." >&2
  echo "Before: $BEFORE" >&2
  echo "After:  $AFTER" >&2
  exit 1
fi

if codesign -d --verbose=4 "$APP" 2>&1 | grep -q '^Signature=adhoc$'; then
  echo "FAIL: Display Workspace is ad-hoc signed." >&2
  exit 1
fi

echo "PASS: Display Workspace keeps a stable Accessibility identity across rebuilds."
