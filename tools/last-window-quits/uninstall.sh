#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST="$HOME/Library/LaunchAgents/com.mikerosoft.last-window-quits.plist"

bash "$SCRIPT_DIR/kill.sh"
if [[ -f "$PLIST" ]]; then
  rm "$PLIST"
fi

echo "Stopped Last Window Quits and removed it from login."
echo "The app remains at ~/Applications/Last Window Quits.app and can be removed manually."
