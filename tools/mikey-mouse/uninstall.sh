#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST="$HOME/Library/LaunchAgents/com.mikerosoft.mikey-mouse.plist"

bash "$SCRIPT_DIR/kill.sh"
if [[ -f "$PLIST" ]]; then
  rm "$PLIST"
fi

echo "Stopped Mikey Mouse and removed it from login."
echo "The app remains at ~/Applications/Mikey Mouse.app and can be removed manually."
