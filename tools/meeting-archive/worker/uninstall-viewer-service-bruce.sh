#!/bin/bash
# Disable only the viewer LaunchAgent. Archives and Tailscale routes remain unchanged.

set -euo pipefail

readonly LABEL="com.mikerosoft.meeting-archive.viewer"
readonly PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
readonly DOMAIN="gui/$(/usr/bin/id -u)"

/bin/launchctl disable "${DOMAIN}/${LABEL}" 2>/dev/null || true
if /bin/launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; then
    /bin/launchctl bootout "${DOMAIN}/${LABEL}"
fi
if [[ -f "${PLIST}" && ! -L "${PLIST}" ]]; then
    /bin/rm -f "${PLIST}"
elif [[ -L "${PLIST}" ]]; then
    echo "Refusing to remove symlinked LaunchAgent: ${PLIST}" >&2
    exit 1
fi

echo "Disabled and unstaged ${LABEL}. Archives, SQLite state, and Tailscale Serve were preserved."
