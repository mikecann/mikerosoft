#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${PHONE_MIRROR_APP_DIR:-$HOME/Applications/Phone Mirror.app}"

bash "$SCRIPT_DIR/kill.sh" >/dev/null || true
PHONE_MIRROR_BUILD_CONFIGURATION=debug bash "$SCRIPT_DIR/build-app.sh"
open "$APP_DIR"
echo "Phone Mirror launched."
