#!/usr/bin/env bash
# Install and start Last Window Quits as a per-user login service.

set -euo pipefail

APP_DIR="${LAST_WINDOW_QUITS_APP_DIR:-$HOME/Applications/Last Window Quits.app}"
APP_BIN="$APP_DIR/Contents/MacOS/last-window-quits"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/com.mikerosoft.last-window-quits.plist"
LOG="$HOME/Library/Logs/last-window-quits.log"
DOMAIN="gui/$(id -u)"
SERVICE="$DOMAIN/com.mikerosoft.last-window-quits"

if [[ ! -x "$APP_BIN" ]]; then
  echo "ERROR: staged app not found. Build it first:"
  echo "  bash tools/last-window-quits/build-app.sh"
  exit 1
fi

mkdir -p "$PLIST_DIR" "$(dirname "$LOG")"

cat >"$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mikerosoft.last-window-quits</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
PLIST

launchctl bootout "$SERVICE" 2>/dev/null || true

# launchd can briefly retain the old job after bootout, especially when the app
# bundle was just replaced. Retry the bootstrap instead of making a normal
# development restart randomly fail with "Input/output error".
bootstrapped=0
for _ in 1 2 3 4 5; do
  if launchctl bootstrap "$DOMAIN" "$PLIST_PATH" 2>/dev/null; then
    bootstrapped=1
    break
  fi
  sleep 0.5
done
if [[ "$bootstrapped" -ne 1 ]]; then
  launchctl bootstrap "$DOMAIN" "$PLIST_PATH"
fi

launchctl kickstart -k "$SERVICE"

echo "Installed and started Last Window Quits."
echo "App: $APP_DIR"
echo "Log: $LOG"
