#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${TOKEN_STATS_APP_DIR:-$HOME/Applications/Token Stats.app}"

bash "$SCRIPT_DIR/kill.sh"
TOKEN_STATS_BUILD_CONFIGURATION=debug bash "$SCRIPT_DIR/build-app.sh"
open "$APP_DIR"
echo "Token Stats launched."
