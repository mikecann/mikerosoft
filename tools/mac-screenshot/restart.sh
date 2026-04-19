#!/usr/bin/env bash
# restart.sh - kill any existing instance and relaunch in the background.
# Usage:  bash tools/mac-screenshot/restart.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$SCRIPT_DIR/.venv"
LOG="$HOME/Library/Logs/mac-screenshot.log"
PLIST_PATH="$HOME/Library/LaunchAgents/com.mikerosoft.mac-screenshot.plist"

if [ ! -f "$VENV/bin/python3" ]; then
  echo "ERROR: venv not found at $VENV"
  echo "Run setup first:  bash $SCRIPT_DIR/setup_mac.sh"
  exit 1
fi

echo "Stopping existing mac-screenshot instances..."
pkill -f "mac-screenshot.py" 2>/dev/null || true
sleep 0.3

if [ -f "$PLIST_PATH" ]; then
  echo "Restarting via LaunchAgent..."
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  sleep 0.3
  launchctl load "$PLIST_PATH"
  echo "Started via LaunchAgent. Hotkey: F11"
  echo "Tail log:  tail -f $LOG"
  exit 0
fi

echo "Launching mac-screenshot..."
nohup "$VENV/bin/python3" "$SCRIPT_DIR/mac-screenshot.py" > /dev/null 2>> "$LOG" &
echo "Started (pid $!). Hotkey: F11"
echo "Tail log:  tail -f $LOG"
