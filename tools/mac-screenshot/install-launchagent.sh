#!/usr/bin/env bash
# install-launchagent.sh - install mac-screenshot as a login item.
# Runs automatically on login and restarts if it crashes.
# Usage:  bash tools/mac-screenshot/install-launchagent.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$SCRIPT_DIR/.venv"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="com.mikerosoft.mac-screenshot.plist"
PLIST_PATH="$PLIST_DIR/$PLIST_NAME"
PYTHON="$VENV/bin/python3"
LOG="$HOME/Library/Logs/mac-screenshot.log"

if [ ! -f "$PYTHON" ]; then
  echo "ERROR: venv not found. Run setup first:"
  echo "  bash $SCRIPT_DIR/setup_mac.sh"
  exit 1
fi

mkdir -p "$PLIST_DIR"

cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mikerosoft.mac-screenshot</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON</string>
        <string>$SCRIPT_DIR/mac-screenshot.py</string>
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

# Unload first in case it was already loaded
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo "Installed and started mac-screenshot as a login item."
echo ""
echo "  Hotkey:     F12"
echo "  Save dir:   ~/Desktop/Screenshots"
echo "  Log:        $LOG"
echo ""
echo "To remove:  bash $SCRIPT_DIR/uninstall-launchagent.sh"
