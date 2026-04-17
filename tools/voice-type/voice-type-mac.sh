#!/usr/bin/env bash
# voice-type-mac.sh — kill any existing instance and relaunch in the background.
# Equivalent of restart.bat on Windows.
#
# Usage: bash tools/voice-type/voice-type-mac.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$SCRIPT_DIR/.venv"
LOG="$SCRIPT_DIR/voice-type.log"

if [ ! -f "$VENV/bin/python3" ]; then
  echo "ERROR: venv not found at $VENV"
  echo "Run setup first:  bash $SCRIPT_DIR/setup_mac.sh"
  exit 1
fi

echo "Stopping existing voice-type instances..."
pkill -f "voice-type.py" 2>/dev/null || true
pkill -f "voice-type-menubar-mac.py" 2>/dev/null || true
sleep 0.5

echo "Launching voice-type..."
# Discard stdout — the Python script writes its own log to voice-type.log directly.
# Only capture stderr (Python warnings / unhandled tracebacks) into the log.
nohup "$VENV/bin/python3" "$SCRIPT_DIR/voice-type.py" > /dev/null 2>> "$LOG" &
MAIN_PID=$!
echo "Started main pid $MAIN_PID."
echo "Tail log with:"
echo "  tail -f $LOG"
echo "Open settings with:"
echo "  bash $SCRIPT_DIR/open-settings-mac.sh"
