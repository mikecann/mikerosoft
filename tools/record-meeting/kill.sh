#!/usr/bin/env bash

set -euo pipefail

APP_DIR="${RECORD_MEETING_APP_DIR:-$HOME/Applications/Record Meeting.app}"
APP_BIN="$APP_DIR/Contents/MacOS/record-meeting-swift"

if pkill -f "$APP_BIN" 2>/dev/null; then
  echo "Record Meeting stopped."
else
  echo "No running Record Meeting instance found."
fi
