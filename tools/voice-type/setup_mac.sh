#!/usr/bin/env bash
# setup_mac.sh — install Python dependencies for voice-type on macOS.
# Run once before first use:  bash tools/voice-type/setup_mac.sh

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
    /usr/local/bin/python3 \
    python3; do
  if command -v "$candidate" &>/dev/null; then
    ver=$("$candidate" -c "import sys; print(sys.version_info[:2])" 2>/dev/null || echo "")
    if [[ "$ver" > "(3, 9)" ]] && [[ "$candidate" != "/usr/bin/python3" ]]; then
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

# Ensure tkinter is available (separate formula on Homebrew)
if ! "$PYTHON" -c "import tkinter" 2>/dev/null; then
  echo "==> Installing python-tk (required for the overlay UI)..."
  brew install python-tk@3.12 || brew install python-tk 2>/dev/null || true
fi

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

packages=(
  "faster-whisper"
  "mlx-whisper"
  "sounddevice"
  "numpy"
  "Pillow"
  "pystray"
  "pynput"
  "sherpa-onnx"
  "huggingface_hub"
  "llama-cpp-python"
  "pyobjc-framework-Cocoa"
  "rumps"
)

for pkg in "${packages[@]}"; do
  echo "  -> $pkg"
  "$PIP" install --quiet "$pkg"
done

echo ""
echo "==> Building native Voice Type launcher..."
if ! command -v xcrun &>/dev/null; then
  echo "ERROR: Xcode Command Line Tools are required to build the launcher."
  echo "Install them with:  xcode-select --install"
  exit 1
fi

PYTHON_CONFIG=$("$VENV/bin/python3" -c \
  'import os, sys, sysconfig; print(os.path.join(sysconfig.get_config_var("BINDIR"), f"python{sys.version_info.major}.{sys.version_info.minor}-config"))')
if [ ! -x "$PYTHON_CONFIG" ]; then
  echo "ERROR: Python embed configuration not found at $PYTHON_CONFIG"
  exit 1
fi

# Arrays preserve each compiler/linker argument returned by the selected
# interpreter. This supports framework and non-framework Python builds.
PYTHON_CFLAGS=( $("$PYTHON_CONFIG" --embed --cflags) )
PYTHON_LDFLAGS=( $("$PYTHON_CONFIG" --embed --ldflags) )
LAUNCHER="$VENV/bin/Voice Type"

xcrun clang "$SCRIPT_DIR/voice-type-launcher.c" \
  "${PYTHON_CFLAGS[@]}" \
  "${PYTHON_LDFLAGS[@]}" \
  -o "$LAUNCHER"
codesign --force --sign - --identifier com.mikerosoft.voice-type "$LAUNCHER"

echo ""
echo "==> All packages installed."
echo ""
echo "  IMPORTANT: voice-type needs Accessibility permissions to detect"
echo "  keypresses and inject text into other apps."
echo ""
echo "  Go to: System Settings > Privacy & Security > Accessibility"
echo "  Add your terminal app and grant access."
echo ""
echo "  First run will download Whisper models (~75 MB tiny, ~244 MB small)."
echo "  They cache to ~/.cache/huggingface/ automatically."
echo ""
echo "  Launch with:"
echo "    bash $SCRIPT_DIR/voice-type-mac.sh"
echo ""
echo "  Or directly:"
echo "    '$LAUNCHER' $SCRIPT_DIR/voice-type.py"
