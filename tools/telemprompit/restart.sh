#!/usr/bin/env bash
# Stop, rebuild (debug), and relaunch. The daily dev command.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${TELEMPROMPIT_APP_DIR:-$HOME/Applications/Telemprompit.app}"

TELEMPROMPIT_BUILD_CONFIGURATION=debug bash "$SCRIPT_DIR/build-app.sh"
open "$APP_DIR"
echo "Telemprompit launched."
