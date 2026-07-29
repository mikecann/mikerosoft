#!/usr/bin/env bash
# setup_mac.sh — install Python dependencies for voice-type on macOS.
# Run once before first use:  bash tools/voice-type/setup_mac.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${VOICE_TYPE_INSTALL_DIR:-$HOME/Library/Application Support/Voice Type}"
TRUSTED_LAUNCHER="${VOICE_TYPE_TRUSTED_LAUNCHER:-}"

# Preserve the path macOS has already approved for Accessibility when upgrading
# an existing installation. The worker and LaunchAgent still live under the
# durable install directory; only the tiny native host uses its approved path.
if [[ -z "$TRUSTED_LAUNCHER" && -x "$SCRIPT_DIR/.venv/bin/Voice Type" ]]; then
  TRUSTED_LAUNCHER="$SCRIPT_DIR/.venv/bin/Voice Type"
fi
if [[ -z "$TRUSTED_LAUNCHER" && -f "$HOME/Library/LaunchAgents/com.mikerosoft.voice-type.plist" ]]; then
  existing_program="$(/usr/libexec/PlistBuddy \
    -c "Print :ProgramArguments:0" \
    "$HOME/Library/LaunchAgents/com.mikerosoft.voice-type.plist" 2>/dev/null || true)"
  if [[ "$(basename "$existing_program")" == "Voice Type" && -x "$existing_program" ]]; then
    TRUSTED_LAUNCHER="$existing_program"
  fi
fi

bash "$SCRIPT_DIR/install-runtime-mac.sh"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
VENV="$INSTALL_DIR/.venv"

if [[ -n "$TRUSTED_LAUNCHER" && "$TRUSTED_LAUNCHER" != "$VENV/bin/Voice Type" ]]; then
  printf '%s\n' "$TRUSTED_LAUNCHER" > "$INSTALL_DIR/trusted-launcher-path"
  chmod 0600 "$INSTALL_DIR/trusted-launcher-path"
  echo "==> Preserving approved Accessibility launcher path: $TRUSTED_LAUNCHER"
fi

# ---------------------------------------------------------------------------
# Find a usable Python 3.10+
# ---------------------------------------------------------------------------
PYTHON=""
if command -v uv &>/dev/null; then
  PYTHON="$(uv python find 3.12 2>/dev/null || true)"
fi

if [[ -z "$PYTHON" ]]; then
  for candidate in \
      /opt/homebrew/bin/python3.13 \
      /opt/homebrew/bin/python3.12 \
      /opt/homebrew/bin/python3.11 \
      /opt/homebrew/bin/python3.10 \
      /usr/local/bin/python3 \
      python3; do
    if command -v "$candidate" &>/dev/null; then
      major=$("$candidate" -c "import sys; print(sys.version_info.major)" 2>/dev/null || echo "0")
      minor=$("$candidate" -c "import sys; print(sys.version_info.minor)" 2>/dev/null || echo "0")
      if [[ "$major" == "3" ]] && [[ "$minor" -ge "10" ]] && [[ "$candidate" != "/usr/bin/python3" ]]; then
        PYTHON="$candidate"
        break
      fi
    fi
  done
fi

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

echo ""
echo "==> Installing Python packages..."
"$VENV/bin/python3" -m pip install --quiet --upgrade pip

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
  "$VENV/bin/python3" -m pip install --quiet "$pkg"
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
PYTHON_LIBDIR=$("$VENV/bin/python3" -c 'import sysconfig; print(sysconfig.get_config_var("LIBDIR") or "")')
if [[ -n "$PYTHON_LIBDIR" ]] && [[ -f "$PYTHON_LIBDIR/libpython${PYTHON_VERSION:-3.12}.dylib" || -d "$PYTHON_LIBDIR" ]]; then
  PYTHON_LDFLAGS+=("-L$PYTHON_LIBDIR" "-Wl,-rpath,$PYTHON_LIBDIR")
fi
LAUNCHER="$VENV/bin/Voice Type"

if [[ -x "$LAUNCHER" && "${VOICE_TYPE_REBUILD_LAUNCHER:-0}" != "1" ]]; then
  # Accessibility permission follows the launcher's code requirement. An
  # unnecessary ad-hoc rebuild changes its cdhash and silently loses TCC trust.
  echo "==> Preserving existing native launcher identity."
else
  xcrun clang "$INSTALL_DIR/voice-type-launcher.c" \
    "${PYTHON_CFLAGS[@]}" \
    "${PYTHON_LDFLAGS[@]}" \
    -o "$LAUNCHER"
  codesign --force --sign - \
    --identifier com.mikerosoft.voice-type \
    --requirements '=designated => identifier "com.mikerosoft.voice-type"' \
    "$LAUNCHER"
fi

echo ""
echo "==> Installing Spotlight application..."
bash "$INSTALL_DIR/install-spotlight-app.sh"

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
echo "    '$LAUNCHER' '$INSTALL_DIR/voice-type.py'"
echo ""
echo "  Open settings from Spotlight by searching for Voice Type."
