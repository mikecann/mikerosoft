#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${RECORD_MEETING_APP_DIR:-$HOME/Applications/Record Meeting.app}"

bash "$SCRIPT_DIR/kill.sh" >/dev/null || true
RECORD_MEETING_BUILD_CONFIGURATION=debug bash "$SCRIPT_DIR/build-app.sh"
open "$APP_DIR"
echo "Record Meeting launched."
