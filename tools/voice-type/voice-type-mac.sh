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

# Wait for the old instance to actually exit before launching a new one.
# A wedged process (e.g. pegged in transcription) can ignore SIGTERM long
# enough for a second instance to start; escalate to SIGKILL if it lingers.
for _ in $(seq 1 20); do
  pgrep -f "voice-type.py" >/dev/null 2>&1 || break
  sleep 0.25
done
if pgrep -f "voice-type.py" >/dev/null 2>&1; then
  echo "Existing instance did not exit; force-killing..."
  pkill -9 -f "voice-type.py" 2>/dev/null || true
  sleep 0.5
fi

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
