#!/usr/bin/env bash
# Install filmora-hotkey as a per-user login daemon.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="$SCRIPT_DIR/.venv/bin/python3"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/com.mikerosoft.filmora-hotkey.plist"
LOG="$HOME/Library/Logs/filmora-hotkey.log"

if [ ! -x "$PYTHON" ]; then
  echo "ERROR: Run setup first:"
  echo "  bash $SCRIPT_DIR/setup_mac.sh"
  exit 1
fi

mkdir -p "$PLIST_DIR"

cat >"$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mikerosoft.filmora-hotkey</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON</string>
        <string>$SCRIPT_DIR/filmora_hotkey.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
PLIST

launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo "Installed and started filmora-hotkey."
echo "Hotkey: F16"
echo "Log: $LOG"
