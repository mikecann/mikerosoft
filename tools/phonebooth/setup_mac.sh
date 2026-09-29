#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PHONEBOOTH_BUILD_CONFIGURATION=release bash "$SCRIPT_DIR/build-app.sh"

echo ""
echo "Phonebooth is installed at ~/Applications/Phonebooth.app"
echo "Launch it with: phonebooth"
echo "macOS will ask for Camera permission on first use. A plugged-in iPhone's screen counts as a camera."
