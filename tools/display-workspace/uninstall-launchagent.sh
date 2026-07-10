#!/usr/bin/env bash

set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/com.mikerosoft.display-workspace.plist"

launchctl bootout "gui/$UID" "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
echo "Removed Display Workspace login item."
