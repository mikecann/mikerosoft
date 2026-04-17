#!/usr/bin/env bash
# setup_mac.sh - install Python dependencies for mac-screenshot.
# Run once before first use:  bash tools/mac-screenshot/setup_mac.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$SCRIPT_DIR/.venv"

# ---------------------------------------------------------------------------
# Find a usable Python 3.10+
# ---------------------------------------------------------------------------
PYTHON=""
for candidate in \
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
  if [ -x "$candidate" ] || command -v "$candidate" &>/dev/null; then
    minor=$("$candidate" -c "import sys; print(sys.version_info.minor)" 2>/dev/null || echo "0")
    major=$("$candidate" -c "import sys; print(sys.version_info.major)" 2>/dev/null || echo "0")
    if [[ "$major" == "3" ]] && [[ "$minor" -ge "10" ]] && [[ "$candidate" != "/usr/bin/python3" ]]; then
      PYTHON="$candidate"
      break
    fi
  fi
done

if [ -z "$PYTHON" ]; then
  echo "ERROR: No suitable Python 3.10+ found."
  echo "Install via:  brew install python@3.12"
  exit 1
fi

echo "==> Using Python: $PYTHON ($($PYTHON --version))"

# ---------------------------------------------------------------------------
# Create / reuse virtual environment
# ---------------------------------------------------------------------------
if [ ! -f "$VENV/bin/python3" ]; then
  echo "==> Creating virtual environment at $VENV..."
  "$PYTHON" -m venv "$VENV"
else
  echo "==> Virtual environment already exists, updating packages..."
fi

PIP="$VENV/bin/pip"

echo ""
echo "==> Installing Python packages..."
"$PIP" install --quiet --upgrade pip
"$PIP" install --quiet pynput

echo ""
echo "==> All packages installed."
echo ""
echo "  IMPORTANT: mac-screenshot needs Accessibility permissions to detect"
echo "  the global hotkey (F12) system-wide."
echo ""
echo "  Go to: System Settings > Privacy & Security > Accessibility"
echo "  Add your terminal app (or the Python binary) and grant access."
echo ""
echo "  To start the daemon now:"
echo "    bash $SCRIPT_DIR/restart.sh"
echo ""
echo "  To install as a login item (auto-start on boot):"
echo "    bash $SCRIPT_DIR/install-launchagent.sh"
