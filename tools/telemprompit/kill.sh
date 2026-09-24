#!/usr/bin/env bash

set -euo pipefail

APP_DIR="${TELEMPROMPIT_APP_DIR:-$HOME/Applications/Telemprompit.app}"
APP_BIN="$APP_DIR/Contents/MacOS/telemprompit"

if pkill -f "$APP_BIN" 2>/dev/null; then
  echo "Telemprompit stopped."
else
  echo "No running Telemprompit instance found."
fi
