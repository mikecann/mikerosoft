#!/usr/bin/env bash

set -euo pipefail

LABEL="com.mikerosoft.photo-backup"
DOMAIN="gui/$(id -u)"
INSTALL_ROOT="$HOME/Library/Application Support/photo-backup"
RUNNER="$INSTALL_ROOT/source/photo-backup"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/photo-backup"
OUT_LOG="$LOG_DIR/automation.log"
ERROR_LOG="$LOG_DIR/automation-error.log"

if [[ ! -x "$RUNNER" ]]; then
  echo "photo-backup: stable installation is missing" >&2
  echo "Run scripts/bruce/photo-backup/setup_mac.sh first." >&2
  exit 1
fi

mkdir -p "$PLIST_DIR" "$LOG_DIR"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$HOME/Library/Application Support/photo-backup/source/photo-backup</string>
        <string>auto</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>21600</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>Nice</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>$OUT_LOG</string>
    <key>StandardErrorPath</key>
    <string>$ERROR_LOG</string>
</dict>
</plist>
PLIST

plutil -lint "$PLIST_PATH" >/dev/null
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST_PATH"

echo "Installed automatic photo backup."
echo "  Schedule: at login and every 6 hours"
echo "  Log: $OUT_LOG"
echo "  Errors: $ERROR_LOG"
