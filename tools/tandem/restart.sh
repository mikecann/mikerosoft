#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${TANDEM_APP_DIR:-$HOME/Applications/Tandem.app}"

bash "$SCRIPT_DIR/kill.sh" >/dev/null || true
TANDEM_BUILD_CONFIGURATION=debug bash "$SCRIPT_DIR/build-app.sh"
if [[ $# -gt 0 ]]; then
  open -a "$APP_DIR" "$@"
else
  open "$APP_DIR"
fi
echo "Tandem launched."
