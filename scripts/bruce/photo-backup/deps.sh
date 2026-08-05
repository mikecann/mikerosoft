#!/usr/bin/env bash

set -euo pipefail

INSTALL_ROOT="${PHOTO_BACKUP_INSTALL_ROOT:-$HOME/Library/Application Support/photo-backup}"
VENV="$INSTALL_ROOT/venv"
OSXPHOTOS_VERSION="0.76.1"
export XDG_CONFIG_HOME="$INSTALL_ROOT/xdg/config"
export XDG_DATA_HOME="$INSTALL_ROOT/xdg/data"
export XDG_CACHE_HOME="$INSTALL_ROOT/xdg/cache"

choose_python() {
  local candidate
  for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if [[ -x "$candidate" ]]; then
      "$candidate" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))' \
        >/dev/null 2>&1 || continue
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "photo-backup: Python 3.10 or newer is required" >&2
  return 1
}

PYTHON="$(choose_python)"
mkdir -p "$INSTALL_ROOT" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"

if [[ ! -x "$VENV/bin/python" ]]; then
  echo "Creating photo-backup Python environment..."
  "$PYTHON" -m venv "$VENV"
fi

if "$VENV/bin/python" -c \
  "import importlib.metadata as m; raise SystemExit(m.version('osxphotos') != '$OSXPHOTOS_VERSION')" \
  >/dev/null 2>&1; then
  echo "osxphotos $OSXPHOTOS_VERSION is already installed."
else
  echo "Installing osxphotos $OSXPHOTOS_VERSION..."
  "$VENV/bin/python" -m pip install --disable-pip-version-check \
    "osxphotos==$OSXPHOTOS_VERSION"
fi

echo "Photo backup dependencies are ready."
