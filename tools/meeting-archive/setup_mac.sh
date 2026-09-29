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

# A replaced bundle is refused by launchd (EX_CONFIG) until its login item is
# registered again from the app itself; registering from a shell is not enough.
# Going through LaunchServices with `open` makes the app the registrant.
AGENT="gui/$(id -u)/com.mikerosoft.meeting-archive"
if launchctl print "$AGENT" >/dev/null 2>&1; then
  APP="$HOME/Applications/Meeting Archive.app"
  open -W -n "$APP" --args --disable-startup 2>/dev/null || true
  open -W -n "$APP" --args --enable-startup 2>/dev/null || true
  sleep 2
  launchctl kickstart "$AGENT" 2>/dev/null || true
  sleep 3
  if launchctl print "$AGENT" 2>/dev/null | grep -q "state = running"; then
    echo "Login item re-registered; Meeting Archive is running in the background."
  else
    echo "Login item needs attention: open Meeting Archive, then Settings > Disable at login, Enable at login." >&2
  fi
else
  echo "Open the app yourself after reviewing the permissions in the README."
fi
