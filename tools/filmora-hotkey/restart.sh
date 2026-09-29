#!/usr/bin/env bash
# Stop every existing instance before starting exactly one replacement.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="$SCRIPT_DIR/.venv/bin/python3"
PLIST_PATH="$HOME/Library/LaunchAgents/com.mikerosoft.filmora-hotkey.plist"
LOG="$HOME/Library/Logs/filmora-hotkey.log"

if [ ! -x "$PYTHON" ]; then
  echo "ERROR: setup has not been run."
  echo "Run: bash $SCRIPT_DIR/setup_mac.sh"
  exit 1
fi

pkill -f "[f]ilmora_hotkey.py" 2>/dev/null || true

if [ -f "$PLIST_PATH" ]; then
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  launchctl load "$PLIST_PATH"
  echo "Restarted filmora-hotkey via LaunchAgent. Hotkey: F16"
else
  nohup "$PYTHON" "$SCRIPT_DIR/filmora_hotkey.py" >/dev/null 2>>"$LOG" &
  echo "Started filmora-hotkey (pid $!). Hotkey: F16"
fi

echo "Log: $LOG"
