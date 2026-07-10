#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${DISPLAY_WORKSPACE_APP:-$HOME/Applications/Display Workspace.app}"

bash "$SCRIPT_DIR/kill.sh"

if [ ! -x "$APP/Contents/MacOS/display-workspace" ]; then
  echo "Display Workspace is not built. Run: bash $SCRIPT_DIR/build.sh" >&2
  exit 1
fi

if launchctl print "gui/$UID/com.mikerosoft.display-workspace" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$UID/com.mikerosoft.display-workspace"
else
  open -na "$APP"
fi
echo "Restarted $APP"
