#!/usr/bin/env bash

set -euo pipefail

APP_DIR="${PHONEBOOTH_APP_DIR:-$HOME/Applications/Phonebooth.app}"
APP_BIN="$APP_DIR/Contents/MacOS/phonebooth-swift"
SUPPORT_DIR="${PHONEBOOTH_SUPPORT_DIR:-$HOME/Library/Application Support/Phonebooth}"

if pkill -f "$APP_BIN" 2>/dev/null; then
  echo "Phonebooth stopped."
else
  echo "No running Phonebooth instance found."
fi

# A killed app can't stop its phone helpers, so stop any xcodebuild still running them.
if pkill -f "xcodebuild test-without-building -xctestrun $SUPPORT_DIR" 2>/dev/null; then
  echo "Phone helpers stopped."
fi
