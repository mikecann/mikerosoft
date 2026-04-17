#!/usr/bin/env bash
# open-settings-mac.sh — open the voice-type settings dialog on macOS.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$SCRIPT_DIR/.venv"
SOCKET_PATH="$SCRIPT_DIR/voice-type-control.sock"

if [ ! -f "$VENV/bin/python3" ]; then
  echo "ERROR: venv not found at $VENV"
  echo "Run setup first:  bash $SCRIPT_DIR/setup_mac.sh"
  exit 1
fi

if [ ! -S "$SOCKET_PATH" ]; then
  echo "voice-type is not running, starting it first..."
  bash "$SCRIPT_DIR/voice-type-mac.sh" >/dev/null
fi

for _ in $(seq 1 40); do
  if [ -S "$SOCKET_PATH" ]; then
    break
  fi
  sleep 0.25
done

if [ ! -S "$SOCKET_PATH" ]; then
  echo "ERROR: voice-type control socket did not appear."
  echo "Check the log: tail -f $SCRIPT_DIR/voice-type.log"
  exit 1
fi

VOICE_TYPE_SCRIPT_DIR="$SCRIPT_DIR" "$VENV/bin/python3" - <<'PY'
import os
import sys

SCRIPT_DIR = os.environ["VOICE_TYPE_SCRIPT_DIR"]
sys.path.insert(0, SCRIPT_DIR)

from voice_type_control import send_request

socket_path = os.path.join(SCRIPT_DIR, "voice-type-control.sock")
response = send_request(socket_path, {"command": "show_settings"})
if not response.get("ok"):
    raise SystemExit(response.get("error", "show_settings failed"))
PY
