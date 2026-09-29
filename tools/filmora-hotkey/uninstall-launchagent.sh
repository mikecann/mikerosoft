#!/usr/bin/env bash

set -euo pipefail

PLIST_PATH="$HOME/Library/LaunchAgents/com.mikerosoft.filmora-hotkey.plist"

if [ ! -f "$PLIST_PATH" ]; then
  echo "filmora-hotkey LaunchAgent is not installed."
  exit 0
fi

launchctl unload "$PLIST_PATH" 2>/dev/null || true
rm "$PLIST_PATH"
echo "filmora-hotkey login daemon removed."
