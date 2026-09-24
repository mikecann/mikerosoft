#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TELEMPROMPIT_BUILD_CONFIGURATION=release bash "$SCRIPT_DIR/build-app.sh"

echo ""
echo "Telemprompit is installed at ~/Applications/Telemprompit.app"
echo "Launch it from Spotlight or with: telemprompit"
echo "View > Turn On Elgato Prompter asks for Accessibility permission the first time."
