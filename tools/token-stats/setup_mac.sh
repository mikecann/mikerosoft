#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOKEN_STATS_BUILD_CONFIGURATION=release bash "$SCRIPT_DIR/build-app.sh"
echo ""
echo "Token Stats is installed at ~/Applications/Token Stats.app"
echo "Launch it with: token-stats"
