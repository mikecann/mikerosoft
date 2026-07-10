#!/usr/bin/env bash
# First-time setup: verify prerequisites, test, build, and launch the app.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -x "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay" ]; then
  echo "ERROR: BetterDisplay is required in /Applications." >&2
  echo "Install it from https://betterdisplay.cc/ and run setup again." >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "ERROR: Swift is required. Install Xcode first." >&2
  exit 1
fi

bash "$SCRIPT_DIR/run-tests.sh"
bash "$SCRIPT_DIR/build.sh"
bash "$SCRIPT_DIR/restart.sh"

echo ""
echo "Display Workspace is running in the menu bar."
echo "Grant Accessibility access when prompted, then save Laptop and Docked setups."
echo ""
echo "For launch at login:"
echo "  bash $SCRIPT_DIR/install-launchagent.sh"
