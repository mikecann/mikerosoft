#!/usr/bin/env bash

set -euo pipefail

APP_DIR="${LAST_WINDOW_QUITS_APP_DIR:-$HOME/Applications/Last Window Quits.app}"
APP_BIN="$APP_DIR/Contents/MacOS/last-window-quits"
SERVICE="gui/$(id -u)/com.mikerosoft.last-window-quits"

launchctl bootout "$SERVICE" 2>/dev/null || true
pkill -f "^${APP_BIN}$" 2>/dev/null || true
