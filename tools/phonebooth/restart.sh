#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${PHONEBOOTH_APP_DIR:-$HOME/Applications/Phonebooth.app}"

bash "$SCRIPT_DIR/kill.sh" >/dev/null || true
PHONEBOOTH_BUILD_CONFIGURATION=debug bash "$SCRIPT_DIR/build-app.sh"
open "$APP_DIR"
echo "Phonebooth launched."
