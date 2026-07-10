#!/usr/bin/env bash

set -euo pipefail

APP="${DISPLAY_WORKSPACE_APP:-$HOME/Applications/Display Workspace.app}"
EXECUTABLE="$APP/Contents/MacOS/display-workspace"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/com.mikerosoft.display-workspace.plist"
LOG="$HOME/Library/Logs/display-workspace.log"
DOMAIN="gui/$UID"

if [ ! -x "$EXECUTABLE" ]; then
  echo "ERROR: Build Display Workspace first: bash tools/display-workspace/build.sh" >&2
  exit 1
fi

mkdir -p "$PLIST_DIR" "$(dirname "$LOG")"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mikerosoft.display-workspace</string>
    <key>ProgramArguments</key>
    <array>
        <string>$EXECUTABLE</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
PLIST

launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || true
pkill -x display-workspace 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$DOMAIN/com.mikerosoft.display-workspace"

echo "Installed Display Workspace as a login item."
echo "Log: $LOG"
