#!/usr/bin/env bash
# Stable LaunchAgent entry point.
#
# Permanent installation errors exit successfully so KeepAlive does not create
# an endless crash loop. Worker crashes still propagate their non-zero status
# and remain eligible for launchd recovery.

set -u

INSTALL_DIR="${VOICE_TYPE_INSTALL_DIR:-$HOME/Library/Application Support/Voice Type}"
LOG_DIR="${VOICE_TYPE_LOG_DIR:-$HOME/Library/Logs/Voice Type}"
RUNTIME_LAUNCHER="$INSTALL_DIR/.venv/bin/Voice Type"
TRUSTED_LAUNCHER_PATH_FILE="$INSTALL_DIR/trusted-launcher-path"
LAUNCHER="$RUNTIME_LAUNCHER"
if [[ -f "$TRUSTED_LAUNCHER_PATH_FILE" ]]; then
  trusted_launcher="$(head -n 1 "$TRUSTED_LAUNCHER_PATH_FILE")"
  if [[ -x "$trusted_launcher" ]]; then
    LAUNCHER="$trusted_launcher"
  fi
fi
APP="$INSTALL_DIR/voice-type.py"
LAUNCHD_LOG="$LOG_DIR/launchd.log"
LOG_MAX_BYTES="${VOICE_TYPE_LAUNCHD_LOG_MAX_BYTES:-1048576}"
LOG_KEEP_LINES="${VOICE_TYPE_LAUNCHD_LOG_KEEP_LINES:-200}"

mkdir -p "$LOG_DIR"

if [[ -f "$LAUNCHD_LOG" ]]; then
  log_size="$(wc -c < "$LAUNCHD_LOG" | tr -d ' ')"
  if [[ "$log_size" -ge "$LOG_MAX_BYTES" ]]; then
    rotated_log="$(mktemp "$LOG_DIR/launchd-rotate.XXXXXX")"
    tail -n "$LOG_KEEP_LINES" "$LAUNCHD_LOG" > "$rotated_log"
    : > "$LAUNCHD_LOG"
    echo "[launchd log rotated; kept last $LOG_KEEP_LINES lines]" >> "$LAUNCHD_LOG"
    cat "$rotated_log" >> "$LAUNCHD_LOG"
    rm -f "$rotated_log"
  fi
fi

if [[ ! -x "$LAUNCHER" ]]; then
  echo "PERMANENT STARTUP ERROR: launcher missing at $LAUNCHER" >&2
  exit 0
fi
if [[ ! -f "$APP" ]]; then
  echo "PERMANENT STARTUP ERROR: worker missing at $APP" >&2
  exit 0
fi

exec "$LAUNCHER" "$APP"
