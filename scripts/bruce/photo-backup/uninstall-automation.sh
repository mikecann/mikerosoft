#!/usr/bin/env bash

set -euo pipefail

LABEL="com.mikerosoft.photo-backup"
DOMAIN="gui/$(id -u)"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
rm -f "$PLIST_PATH"
echo "Removed automatic photo backup LaunchAgent."
