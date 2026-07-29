#!/usr/bin/env bash
# Stage a self-contained Voice Type source snapshot outside the Git checkout.
#
# The Python environment lives beside this snapshot. Launchd only references
# this stable directory, so deleting a development worktree cannot break login
# startup.

set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${VOICE_TYPE_INSTALL_DIR:-$HOME/Library/Application Support/Voice Type}"

mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/icons"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"

if [[ "$SOURCE_DIR" == "$INSTALL_DIR" ]]; then
  exit 0
fi

for source in "$SOURCE_DIR"/*.py; do
  install -m 0644 "$source" "$INSTALL_DIR/$(basename "$source")"
done

for name in \
  install-runtime-mac.sh \
  install-spotlight-app.sh \
  launch-voice-type-mac.sh \
  open-settings-mac.sh \
  setup_mac.sh \
  voice-type-mac.sh; do
  install -m 0755 "$SOURCE_DIR/$name" "$INSTALL_DIR/$name"
done

install -m 0644 \
  "$SOURCE_DIR/voice-type-launcher.c" \
  "$INSTALL_DIR/voice-type-launcher.c"
install -m 0644 "$SOURCE_DIR/icons/sound.png" "$INSTALL_DIR/icons/sound.png"

# settings.json is user state once installed. Seed it on first install, but
# never overwrite later changes when staging a new runtime.
if [[ ! -f "$INSTALL_DIR/settings.json" ]]; then
  install -m 0600 "$SOURCE_DIR/settings.json" "$INSTALL_DIR/settings.json"
fi

echo "Staged Voice Type runtime: $INSTALL_DIR"
