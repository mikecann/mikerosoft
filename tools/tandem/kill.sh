#!/usr/bin/env bash

set -euo pipefail

APP_DIR="${TANDEM_APP_DIR:-$HOME/Applications/Tandem.app}"
APP_BIN="$APP_DIR/Contents/MacOS/tandem-app"

if pkill -f "$APP_BIN" 2>/dev/null; then
  echo "Tandem stopped."
else
  echo "No running Tandem instance found."
fi
