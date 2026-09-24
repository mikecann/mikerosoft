#!/usr/bin/env bash

set -euo pipefail

APP_DIR="${TELEMPROMPIT_APP_DIR:-$HOME/Applications/Telemprompit.app}"
APP_BIN="$APP_DIR/Contents/MacOS/telemprompit"

if pkill -f "$APP_BIN" 2>/dev/null; then
  # Wait for it to exit so a following `open` starts a fresh process
  # instead of activating the one that is shutting down.
  for _ in $(seq 1 30); do
    pgrep -f "$APP_BIN" >/dev/null || break
    sleep 0.1
  done
  echo "Telemprompit stopped."
else
  echo "No running Telemprompit instance found."
fi
