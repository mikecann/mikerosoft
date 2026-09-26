#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PHONE_MIRROR_BUILD_CONFIGURATION=release bash "$SCRIPT_DIR/build-app.sh"

echo ""
echo "Phone Mirror is installed at ~/Applications/Phone Mirror.app"
echo "Launch it with: phone-mirror"
echo "macOS will ask for Camera permission on first use. A plugged-in iPhone's screen counts as a camera."
