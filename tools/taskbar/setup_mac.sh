#!/usr/bin/env bash
# setup_mac.sh - check Swift and build the taskbar app.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v swift >/dev/null 2>&1; then
  echo "ERROR: swift is not on PATH."
  echo "Install Xcode or Command Line Tools first."
  exit 1
fi

echo "==> Using $(swift --version | head -n 1)"
echo "==> Building taskbar..."
swift build --package-path "$SCRIPT_DIR" -c debug

echo ""
echo "Setup complete."
echo ""
echo "Run:"
echo "  bash $SCRIPT_DIR/restart.sh"
echo ""
echo "restart.sh stages and signs ~/Applications/Mikerosoft Taskbar.app before launching it."
echo "Note: keeping windows above the bar needs Accessibility permission for Mikerosoft Taskbar.app."
