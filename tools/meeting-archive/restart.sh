#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${MEETING_ARCHIVE_APP_DIR:-$HOME/Applications/Meeting Archive.app}"
if pgrep -f "$APP_DIR/Contents/MacOS/meeting-archive-app" >/dev/null; then
  echo "Quit Meeting Archive from its menu before rebuilding, so any live writer can finish." >&2
  exit 1
fi
"$SCRIPT_DIR/build-app.sh"
open "$APP_DIR"
