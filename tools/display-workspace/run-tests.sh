#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

swift test
bash "$SCRIPT_DIR/test-signing.sh"
swift build -c release
".build/release/display-workspace" --diagnose
