#!/bin/bash
# Disable only the LaunchAgent. Archives, queues, models, credentials, and logs remain.

set -euo pipefail

readonly LABEL="com.mikerosoft.meeting-archive.worker"
readonly PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
readonly DOMAIN="gui/$(/usr/bin/id -u)"

# Disabling first prevents KeepAlive from starting a replacement while bootout
# asks the current process to terminate. SQLite leases recover on a later run.
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

echo "Disabled and unstaged ${LABEL}. Meeting archives, SQLite state, models, and credential files were preserved."
