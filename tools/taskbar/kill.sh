#!/usr/bin/env bash
# kill.sh - stop the taskbar prototype.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="/tmp/mikerosoft-taskbar.pid"
LABEL="com.mikerosoft.taskbar"
SERVICE="gui/$(id -u)/$LABEL"
PLIST="/tmp/$LABEL.plist"
APP_NAME="Mikerosoft Taskbar"
APP_DIR="${TASKBAR_APP_DIR:-$HOME/Applications/$APP_NAME.app}"
APP_BIN="$APP_DIR/Contents/MacOS/taskbar-swift"
STOPPED=0

launchctl bootout "$SERVICE" 2>/dev/null && STOPPED=1
rm -f "$PLIST"

if [ -f "$PID_FILE" ]; then
  PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null && STOPPED=1
  fi
  rm -f "$PID_FILE"
fi

pkill -f "$SCRIPT_DIR/taskbar.py" 2>/dev/null && STOPPED=1
pkill -f "tools/taskbar/taskbar.py" 2>/dev/null && STOPPED=1
pkill -f "$APP_BIN" 2>/dev/null && STOPPED=1
pkill -f "$SCRIPT_DIR/.build/.*/taskbar-swift" 2>/dev/null && STOPPED=1
pkill -f "taskbar-swift" 2>/dev/null && STOPPED=1

if [ "$STOPPED" -eq 1 ]; then
  echo "taskbar stopped."
else
  echo "No running taskbar instance found."
fi
