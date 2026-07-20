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

wait_for_socket() {
  for _ in $(seq 1 80); do
    [ -S "$SOCKET_PATH" ] && return 0
    sleep 0.25
  done
  return 1
}

send_settings_request() {
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
}

if [ ! -S "$SOCKET_PATH" ]; then
  echo "voice-type is not running, starting it first..."
  bash "$SCRIPT_DIR/voice-type-mac.sh" >/dev/null
  wait_for_socket || {
    echo "ERROR: voice-type control socket did not appear."
    echo "Check the log: tail -f $SCRIPT_DIR/voice-type.log"
    exit 1
  }
fi

if ! send_settings_request; then
  restart_after_failed_request=1
  echo "voice-type control socket is stale; restarting the worker..."
  rm -f "$SOCKET_PATH"
  bash "$SCRIPT_DIR/voice-type-mac.sh" >/dev/null
  wait_for_socket || {
    echo "ERROR: voice-type did not restart successfully."
    echo "Check the log: tail -f $SCRIPT_DIR/voice-type.log"
    exit 1
  }
  send_settings_request
fi
