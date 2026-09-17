#!/usr/bin/env bash

set -euo pipefail

APP_DIR="${MEETING_ARCHIVE_APP_DIR:-$HOME/Applications/Meeting Archive.app}"
APP_BIN="$APP_DIR/Contents/MacOS/meeting-archive-app"
if [[ ! -x "$APP_BIN" ]]; then
  echo "Open the installed Meeting Archive app's Settings and choose Disable at login." >&2
  exit 1
fi
# Keep the correct signed bundle context. This mode exits before constructing
# the recording controller, so disabling startup cannot start a recording.
"$APP_BIN" --disable-startup
