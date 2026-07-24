#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/build-app.sh"
bash "$SCRIPT_DIR/install-launchagent.sh"

sleep 1

APP_DIR="${LAST_WINDOW_QUITS_APP_DIR:-$HOME/Applications/Last Window Quits.app}"
APP_BIN="$APP_DIR/Contents/MacOS/last-window-quits"
PID="$(pgrep -f "^${APP_BIN}$" | head -n 1 || true)"

if [[ -z "$PID" ]]; then
  echo "ERROR: Last Window Quits did not stay running."
  tail -n 40 "$HOME/Library/Logs/last-window-quits.log" 2>/dev/null || true
  exit 1
fi

echo "Started pid $PID."
