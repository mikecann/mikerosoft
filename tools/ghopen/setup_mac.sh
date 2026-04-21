#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$HOME/.local/bin"
TARGET_PATH="$TARGET_DIR/ghopen"
SOURCE_PATH="$SCRIPT_DIR/ghopen"

mkdir -p "$TARGET_DIR"
chmod +x "$SOURCE_PATH"
ln -sf "$SOURCE_PATH" "$TARGET_PATH"

echo "Installed ghopen to $TARGET_PATH"

case ":$PATH:" in
  *":$TARGET_DIR:"*)
    echo "ghopen is ready to use."
    ;;
  *)
    echo "Add this to your shell profile if needed:"
    echo "  export PATH=\"$TARGET_DIR:\$PATH\""
    ;;
esac
