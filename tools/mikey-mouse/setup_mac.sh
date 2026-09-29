#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v swift >/dev/null 2>&1; then
  echo "ERROR: swift is not on PATH."
  echo "Install Xcode or Command Line Tools first."
  exit 1
fi

echo "==> Using $(swift --version | head -n 1)"
echo "==> Running tests..."
swift test --package-path "$SCRIPT_DIR"

echo ""
echo "==> Building, installing, and starting..."
bash "$SCRIPT_DIR/restart.sh"

echo ""
echo "Setup complete."
echo "Look for the mouse icon in the menu bar."
echo ""
echo "Mikey Mouse needs Accessibility permission to read and rewrite mouse events."
echo "If macOS prompts, enable Mikey Mouse in:"
echo "  System Settings > Privacy & Security > Accessibility"
echo ""
echo "Quit Mac Mouse Fix, SensibleSideButtons, or LinearMouse first if they are"
echo "running, or both apps will try to handle the same buttons."
