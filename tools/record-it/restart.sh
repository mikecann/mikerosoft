#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${RECORD_IT_APP_DIR:-$HOME/Applications/Record It.app}"

bash "$SCRIPT_DIR/kill.sh" >/dev/null || true
RECORD_IT_BUILD_CONFIGURATION=debug bash "$SCRIPT_DIR/build-app.sh"
open "$APP_DIR"
echo "Record It launched."
