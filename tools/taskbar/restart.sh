#!/usr/bin/env bash
# restart.sh - build and relaunch the Swift taskbar app.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HOME/Library/Logs/mikerosoft-taskbar.log"
PID_FILE="/tmp/mikerosoft-taskbar.pid"
LABEL="com.mikerosoft.taskbar"
PLIST="/tmp/$LABEL.plist"
DOMAIN="gui/$(id -u)"
SERVICE="$DOMAIN/$LABEL"
BUILD_CONFIGURATION="${TASKBAR_BUILD_CONFIGURATION:-debug}"
APP_NAME="Mikerosoft Taskbar"
APP_DIR="${TASKBAR_APP_DIR:-$HOME/Applications/$APP_NAME.app}"
APP_BIN="$APP_DIR/Contents/MacOS/taskbar-swift"
SIGNING_IDENTITY="${TASKBAR_CODESIGN_IDENTITY:-}"

if ! command -v swift >/dev/null 2>&1; then
  echo "ERROR: swift is not on PATH."
  echo "Install Xcode or Command Line Tools first."
  exit 1
fi

echo "Building taskbar ($BUILD_CONFIGURATION)..."
swift build --package-path "$SCRIPT_DIR" -c "$BUILD_CONFIGURATION" >/dev/null
BIN_DIR="$(swift build --package-path "$SCRIPT_DIR" -c "$BUILD_CONFIGURATION" --show-bin-path)"
BINARY="$BIN_DIR/taskbar-swift"

if [ ! -x "$BINARY" ]; then
  echo "ERROR: built binary not found at $BINARY"
  exit 1
fi

echo "Stopping existing taskbar instances..."
bash "$SCRIPT_DIR/kill.sh" >/dev/null || true
sleep 0.25

echo "Staging $APP_NAME.app..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_BIN"
chmod +x "$APP_BIN"
cat >"$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>taskbar-swift</string>
    <key>CFBundleIdentifier</key>
    <string>com.mikerosoft.taskbar</string>
    <key>CFBundleName</key>
    <string>Mikerosoft Taskbar</string>
    <key>CFBundleDisplayName</key>
    <string>Mikerosoft Taskbar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

if [ -z "$SIGNING_IDENTITY" ]; then
  SIGNING_IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
      | head -n 1
  )"
fi
if [ -z "$SIGNING_IDENTITY" ]; then
  SIGNING_IDENTITY="-"
fi
codesign --force --deep --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_DIR" >/dev/null

cat >"$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_BIN</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>TASKBAR_APP_EXECUTABLE</key>
        <string>$APP_BIN</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
PLIST

echo "Launching taskbar via launchctl..."
launchctl bootout "$SERVICE" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$SERVICE"
sleep 1

PID="$(pgrep -f "$APP_BIN" | head -n 1 || true)"
if [ -z "$PID" ]; then
  echo "ERROR: taskbar did not stay running."
  echo "Log: $LOG"
  tail -n 40 "$LOG" 2>/dev/null || true
  launchctl print "$SERVICE" 2>/dev/null || true
  exit 1
fi

echo "$PID" >"$PID_FILE"
echo "Started pid $PID."
echo "App: $APP_DIR"
echo "Log: $LOG"
