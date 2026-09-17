#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER_DIR="${MEETING_ARCHIVE_LAUNCHER_DIR:-$HOME/.local/bin}"

usage() {
  cat <<'EOF'
Usage: bash tools/meeting-archive/setup_mac.sh [--with-launcher]

Build and install the signed Meeting Archive.app bundle. The optional launcher
is a symlink in ~/.local/bin (or MEETING_ARCHIVE_LAUNCHER_DIR).
EOF
}

WITH_LAUNCHER=0
for arg in "$@"; do
  case "$arg" in
    --with-launcher) WITH_LAUNCHER=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "meeting-archive setup: unknown option: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

echo "Building and signing Meeting Archive.app..."
bash "$SCRIPT_DIR/build-app.sh"

if [[ "$WITH_LAUNCHER" -eq 1 ]]; then
  mkdir -p "$LAUNCHER_DIR"
  ln -sf "$SCRIPT_DIR/meeting-archive" "$LAUNCHER_DIR/meeting-archive"
  echo "Launcher: $LAUNCHER_DIR/meeting-archive"
fi

echo "Installed: $HOME/Applications/Meeting Archive.app"
echo "Open the app yourself after reviewing the permissions in the README."
