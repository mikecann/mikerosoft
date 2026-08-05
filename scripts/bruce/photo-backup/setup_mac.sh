#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="$HOME/Library/Application Support/photo-backup"
INSTALL_SOURCE="$INSTALL_ROOT/source"

mkdir -p "$INSTALL_SOURCE"
install -m 0755 "$SCRIPT_DIR/photo-backup" "$INSTALL_SOURCE/photo-backup"
install -m 0644 "$SCRIPT_DIR/photo_backup.py" "$INSTALL_SOURCE/photo_backup.py"
install -m 0755 "$SCRIPT_DIR/deps.sh" "$INSTALL_SOURCE/deps.sh"
install -m 0755 "$SCRIPT_DIR/install-automation.sh" "$INSTALL_SOURCE/install-automation.sh"
install -m 0755 "$SCRIPT_DIR/uninstall-automation.sh" "$INSTALL_SOURCE/uninstall-automation.sh"

PHOTO_BACKUP_INSTALL_ROOT="$INSTALL_ROOT" bash "$INSTALL_SOURCE/deps.sh"

echo "Installed Bruce photo backup script to $INSTALL_SOURCE"
echo "Run: \"$INSTALL_SOURCE/photo-backup\" paths"
echo "Automate: \"$INSTALL_SOURCE/install-automation.sh\""
