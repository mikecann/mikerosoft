#!/usr/bin/env bash

set -euo pipefail

APP_DIR="${PHONE_MIRROR_APP_DIR:-$HOME/Applications/Phone Mirror.app}"
APP_BIN="$APP_DIR/Contents/MacOS/phone-mirror-swift"
SUPPORT_DIR="${PHONE_MIRROR_SUPPORT_DIR:-$HOME/Library/Application Support/Phone Mirror}"

if pkill -f "$APP_BIN" 2>/dev/null; then
  echo "Phone Mirror stopped."
else
  echo "No running Phone Mirror instance found."
fi

# A killed app can't stop its phone helpers, so stop any xcodebuild still running them.
if pkill -f "xcodebuild test-without-building -xctestrun $SUPPORT_DIR" 2>/dev/null; then
  echo "Phone helpers stopped."
fi
