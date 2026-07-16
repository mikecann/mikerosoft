#!/usr/bin/env bash

set -euo pipefail

APP_DIR="${RECORD_IT_APP_DIR:-$HOME/Applications/Record It.app}"
APP_BIN="$APP_DIR/Contents/MacOS/record-it-swift"

if pkill -f "$APP_BIN" 2>/dev/null; then
  echo "Record It stopped."
else
  echo "No running Record It instance found."
fi
