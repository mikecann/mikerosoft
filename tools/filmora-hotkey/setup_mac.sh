#!/usr/bin/env bash
# One-time setup for the Filmora F16 global hotkey daemon.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$SCRIPT_DIR/.venv"
PYTHON=""

for candidate in \
  "$HOME/.local/bin/python3" \
  /opt/homebrew/bin/python3.13 \
  /opt/homebrew/bin/python3.12 \
  /opt/homebrew/bin/python3.11 \
  /opt/homebrew/bin/python3.10 \
  /usr/local/bin/python3.13 \
  /usr/local/bin/python3.12 \
  /usr/local/bin/python3.11 \
  /usr/local/bin/python3.10 \
  /usr/local/bin/python3 \
  python3; do
  if [ -x "$candidate" ] || command -v "$candidate" >/dev/null 2>&1; then
    version=$("$candidate" -c 'import sys; print(sys.version_info >= (3, 10))' 2>/dev/null || true)
    if [ "$version" = "True" ] && [ "$candidate" != "/usr/bin/python3" ]; then
      PYTHON="$candidate"
      break
    fi
  fi
done

if [ -z "$PYTHON" ]; then
  echo "ERROR: No suitable Python 3.10+ found."
  echo "Install one with: brew install python@3.12"
  exit 1
fi

echo "Using $PYTHON ($("$PYTHON" --version))"
if [ ! -x "$VENV/bin/python3" ]; then
  "$PYTHON" -m venv "$VENV"
fi

"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet pynput

echo "Dependencies installed."
echo "Grant Accessibility access if macOS asks, then run:"
echo "  bash $SCRIPT_DIR/install-launchagent.sh"
