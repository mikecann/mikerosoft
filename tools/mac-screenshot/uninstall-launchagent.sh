#!/usr/bin/env bash
# uninstall-launchagent.sh - remove the mac-screenshot login item.
# Usage:  bash tools/mac-screenshot/uninstall-launchagent.sh

PLIST_PATH="$HOME/Library/LaunchAgents/com.mikerosoft.mac-screenshot.plist"

if [ ! -f "$PLIST_PATH" ]; then
  echo "LaunchAgent not installed."
  exit 0
fi

launchctl unload "$PLIST_PATH" 2>/dev/null || true
rm "$PLIST_PATH"
echo "mac-screenshot login item removed."
