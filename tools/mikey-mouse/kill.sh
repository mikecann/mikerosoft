#!/usr/bin/env bash

set -euo pipefail

APP_DIR="${MIKEY_MOUSE_APP_DIR:-$HOME/Applications/Mikey Mouse.app}"
APP_BIN="$APP_DIR/Contents/MacOS/mikey-mouse"
SERVICE="gui/$(id -u)/com.mikerosoft.mikey-mouse"

launchctl bootout "$SERVICE" 2>/dev/null || true
pkill -f "^${APP_BIN}$" 2>/dev/null || true
