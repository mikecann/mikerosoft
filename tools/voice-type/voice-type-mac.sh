#!/usr/bin/env bash
# Restart Voice Type and prove that its control server becomes responsive.

set -u

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${VOICE_TYPE_INSTALL_DIR:-$HOME/Library/Application Support/Voice Type}"
LOG_DIR="${VOICE_TYPE_LOG_DIR:-$HOME/Library/Logs/Voice Type}"
LAUNCH_AGENT_PATH="${VOICE_TYPE_LAUNCH_AGENT_PATH:-$HOME/Library/LaunchAgents/com.mikerosoft.voice-type.plist}"

mkdir -p "$INSTALL_DIR" "$LOG_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
LOG_DIR="$(cd "$LOG_DIR" && pwd)"

# Repository commands remain the developer entry point, but the process itself
# always runs from the durable installed snapshot.
if [[ "$SOURCE_DIR" != "$INSTALL_DIR" ]]; then
  if [[ "${1:-}" == "status" ]]; then
    if [[ ! -x "$INSTALL_DIR/voice-type-mac.sh" ]]; then
      echo "Voice Type is not installed at $INSTALL_DIR"
      exit 1
    fi
  else
    bash "$SOURCE_DIR/install-runtime-mac.sh" >/dev/null || exit 1
  fi
  exec env \
    VOICE_TYPE_INSTALL_DIR="$INSTALL_DIR" \
    VOICE_TYPE_LOG_DIR="$LOG_DIR" \
    VOICE_TYPE_LAUNCH_AGENT_PATH="$LAUNCH_AGENT_PATH" \
    bash "$INSTALL_DIR/voice-type-mac.sh" "$@"
fi

VENV="$INSTALL_DIR/.venv"
PYTHON="$VENV/bin/python3"
RUNTIME_LAUNCHER="$VENV/bin/Voice Type"
TRUSTED_LAUNCHER_PATH_FILE="$INSTALL_DIR/trusted-launcher-path"
LAUNCHER="$RUNTIME_LAUNCHER"
if [[ -f "$TRUSTED_LAUNCHER_PATH_FILE" ]]; then
  trusted_launcher="$(head -n 1 "$TRUSTED_LAUNCHER_PATH_FILE")"
  if [[ -x "$trusted_launcher" ]]; then
    LAUNCHER="$trusted_launcher"
  fi
fi
APP="$INSTALL_DIR/voice-type.py"
SOCKET_PATH="$INSTALL_DIR/voice-type-control.sock"
HEARTBEAT_PATH="$INSTALL_DIR/voice-type.heartbeat"
LAUNCHD_LOG="$LOG_DIR/launchd.log"
LAUNCHD_SERVICE="gui/$(id -u)/com.mikerosoft.voice-type"
PLIST_BUDDY="${VOICE_TYPE_PLIST_BUDDY:-/usr/libexec/PlistBuddy}"
READY_TIMEOUT_SECONDS="${VOICE_TYPE_READY_TIMEOUT_SECONDS:-30}"
READY_POLL_SECONDS="${VOICE_TYPE_READY_POLL_SECONDS:-0.25}"

if [[ ! -x "$LAUNCHER" || ! -x "$PYTHON" || ! -f "$APP" ]]; then
  echo "ERROR: the installed Voice Type runtime is incomplete at $INSTALL_DIR"
  echo "Run setup first: bash tools/voice-type/setup_mac.sh"
  exit 1
fi

configured_program() {
  [[ -f "$LAUNCH_AGENT_PATH" ]] || return 1
  "$PLIST_BUDDY" \
    -c "Print :ProgramArguments:0" \
    "$LAUNCH_AGENT_PATH" 2>/dev/null
}

readiness_probe() {
  VOICE_TYPE_SCRIPT_DIR="$INSTALL_DIR" "$PYTHON" - <<'PY' >/dev/null 2>&1
import os
import sys

script_dir = os.environ["VOICE_TYPE_SCRIPT_DIR"]
sys.path.insert(0, script_dir)
from voice_type_control import send_request

response = send_request(
    os.path.join(script_dir, "voice-type-control.sock"),
    {"command": "get_state"},
    timeout_sec=0.5,
)
state = response.get("state") or {}
healthy = (
    response.get("ok")
    and state.get("hotkey_listener") == "event-tap"
)
raise SystemExit(0 if healthy else 1)
PY
}

print_readiness_details() {
  VOICE_TYPE_SCRIPT_DIR="$INSTALL_DIR" "$PYTHON" - <<'PY'
import os
import sys

script_dir = os.environ["VOICE_TYPE_SCRIPT_DIR"]
sys.path.insert(0, script_dir)
from voice_type_control import send_request

try:
    response = send_request(
        os.path.join(script_dir, "voice-type-control.sock"),
        {"command": "get_state"},
        timeout_sec=1.5,
    )
except Exception as error:
    print(f"Control server: unavailable ({error})")
    raise SystemExit(1)

state = response.get("state") or {}
print("Control server: responsive")
print(f"Hotkey listener: {state.get('hotkey_listener', 'unknown')}")
raise SystemExit(
    0 if response.get("ok") and state.get("hotkey_listener") == "event-tap"
    else 1
)
PY
}

wait_for_ready() {
  attempts="$(awk \
    -v timeout="$READY_TIMEOUT_SECONDS" \
    -v poll="$READY_POLL_SECONDS" \
    'BEGIN { n = int(timeout / poll); print (n < 1 ? 1 : n) }')"
  for _ in $(seq 1 "$attempts"); do
    readiness_probe && return 0
    sleep "$READY_POLL_SECONDS"
  done
  return 1
}

print_failure_diagnostics() {
  echo "LaunchAgent state:"
  launchctl print "$LAUNCHD_SERVICE" 2>&1 |
    grep -E "state =|runs =|last exit code|program =|working directory" |
    head -20 || true
  if [[ -f "$LAUNCHD_LOG" ]]; then
    echo "Recent launch errors:"
    tail -n 12 "$LAUNCHD_LOG"
  fi
}

show_status() {
  echo "Install directory: $INSTALL_DIR"
  echo "Expected worker: $APP"
  echo "Active launcher: $LAUNCHER"
  current_program="$(configured_program 2>/dev/null || true)"
  echo "Configured program: ${current_program:-not configured}"
  launchctl print "$LAUNCHD_SERVICE" 2>&1 |
    grep -E "state =|runs =|last exit code|program =|working directory" |
    head -20 || true
  if readiness_probe; then
    echo "Readiness: healthy (control server and native hotkey event tap active)"
    return 0
  fi
  echo "Readiness: unhealthy"
  print_readiness_details || true
  if [[ -f "$HEARTBEAT_PATH" ]]; then
    "$PYTHON" - "$HEARTBEAT_PATH" <<'PY'
import os
import sys
import time
print(f"Heartbeat age: {time.time() - os.path.getmtime(sys.argv[1]):.1f}s")
PY
  else
    echo "Heartbeat: missing"
  fi
  return 1
}

if [[ "${1:-}" == "status" ]]; then
  show_status
  exit $?
fi

# Repair LaunchAgents created by older versions or temporary worktrees before
# asking launchd to restart them.
expected_program="$INSTALL_DIR/launch-voice-type-mac.sh"
current_program="$(configured_program 2>/dev/null || true)"
if [[ -f "$LAUNCH_AGENT_PATH" && "$current_program" != "$expected_program" ]]; then
  echo "Repairing stale Voice Type LaunchAgent..."
  VOICE_TYPE_INSTALL_DIR="$INSTALL_DIR" \
  VOICE_TYPE_LOG_DIR="$LOG_DIR" \
  VOICE_TYPE_LAUNCH_AGENT_PATH="$LAUNCH_AGENT_PATH" \
  PYTHONPATH="$INSTALL_DIR" \
    "$PYTHON" -c \
    "import platform_mac; platform_mac.set_startup(True)"
fi

if launchctl print "$LAUNCHD_SERVICE" >/dev/null 2>&1; then
  echo "Restarting Voice Type via LaunchAgent..."
  echo "$(date '+%Y-%m-%d %H:%M:%S')  Restart requested by voice-type-mac.sh." \
    >> "$LAUNCHD_LOG"
  pkill -f "$APP" 2>/dev/null || true
  for _ in $(seq 1 20); do
    pgrep -f "$APP" >/dev/null 2>&1 || break
    sleep 0.1
  done
  rm -f "$SOCKET_PATH" "$HEARTBEAT_PATH"
  if launchctl kickstart -k "$LAUNCHD_SERVICE"; then
    if wait_for_ready; then
      echo "Restarted via LaunchAgent and verified ready."
      exit 0
    fi
    echo "ERROR: Voice Type did not become ready after launchd accepted the restart."
    print_failure_diagnostics
    exit 1
  fi

  echo "LaunchAgent restart failed; unloading it before a manual relaunch."
  launchctl bootout "$LAUNCHD_SERVICE" 2>/dev/null || true
fi

echo "Stopping existing Voice Type instances..."
pkill -f "$APP" 2>/dev/null || true
rm -f "$SOCKET_PATH" "$HEARTBEAT_PATH"

for _ in $(seq 1 20); do
  pgrep -f "$APP" >/dev/null 2>&1 || break
  sleep 0.25
done
if pgrep -f "$APP" >/dev/null 2>&1; then
  echo "Existing instance did not exit; force-killing..."
  pkill -9 -f "$APP" 2>/dev/null || true
  sleep 0.5
fi

echo "Launching Voice Type..."
nohup "$LAUNCHER" "$APP" > /dev/null 2>> "$LAUNCHD_LOG" &
MAIN_PID=$!
if wait_for_ready; then
  echo "Started main pid $MAIN_PID and verified ready."
  exit 0
fi

echo "ERROR: manually launched Voice Type did not become ready."
print_failure_diagnostics
exit 1
