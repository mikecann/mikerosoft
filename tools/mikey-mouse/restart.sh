#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/build-app.sh"
bash "$SCRIPT_DIR/install-launchagent.sh"

sleep 1

APP_DIR="${MIKEY_MOUSE_APP_DIR:-$HOME/Applications/Mikey Mouse.app}"
APP_BIN="$APP_DIR/Contents/MacOS/mikey-mouse"
PID="$(pgrep -f "^${APP_BIN}$" | head -n 1 || true)"

if [[ -z "$PID" ]]; then
  echo "ERROR: Mikey Mouse did not stay running."
  tail -n 40 "$HOME/Library/Logs/mikey-mouse.log" 2>/dev/null || true
  exit 1
fi

echo "Started pid $PID."
