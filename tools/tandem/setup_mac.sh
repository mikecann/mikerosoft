#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TANDEM_BUILD_CONFIGURATION=release bash "$SCRIPT_DIR/build-app.sh"

echo ""
echo "Tandem is installed at ~/Applications/Tandem.app"
echo "Launch it from Spotlight, or run bash install_mac.sh once to put the tandem command on your PATH."
echo "Agents: claude mcp add tandem -- ~/Applications/Tandem.app/Contents/MacOS/tandem mcp"
