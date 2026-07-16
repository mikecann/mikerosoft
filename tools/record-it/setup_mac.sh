#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RECORD_IT_BUILD_CONFIGURATION=release bash "$SCRIPT_DIR/build-app.sh"

echo ""
echo "Record It is installed at ~/Applications/Record It.app"
echo "Launch it with: record-it"
echo "macOS will ask for Screen Recording, Camera, and Microphone permissions on first use."
