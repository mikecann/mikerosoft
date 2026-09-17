#!/bin/bash
# Stage Bruce's per-user LaunchAgent. Loading it requires explicit --enable.

set -euo pipefail
umask 077

readonly LABEL="com.mikerosoft.meeting-archive.worker"
readonly EXPECTED_VOLUME_UUID="5CCB1D81-5A98-4C4A-9E2C-3E10B23F1B46"
readonly VOLUME_ROOT="/Volumes/CannMedia"
readonly RUNTIME_ROOT="${VOLUME_ROOT}/MeetingArchive/runtime"
readonly WRAPPER="${RUNTIME_ROOT}/worker/run-service-bruce.sh"
# The native bundle owns scoped drive consent. A launchd-owned shell cannot
# inherit the permission that made the same wrapper work in an SSH session.
readonly LAUNCHER="${HOME}/Applications/Meeting Archive Worker.app/Contents/MacOS/meeting-archive-worker"
readonly AGENT_DIRECTORY="${HOME}/Library/LaunchAgents"
readonly PLIST="${AGENT_DIRECTORY}/${LABEL}.plist"
readonly LOG_DIRECTORY="${HOME}/Library/Logs/Meeting Archive"
readonly STDERR_LOG="${LOG_DIRECTORY}/worker.stderr.log"
readonly PREVIOUS_STDERR_LOG="${STDERR_LOG}.previous"

enable=false
case "${1:-}" in
    "") ;;
    --enable) enable=true ;;
    *) echo "Usage: $0 [--enable]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "Usage: $0 [--enable]" >&2; exit 2; }

[[ -d "${VOLUME_ROOT}" && ! -L "${VOLUME_ROOT}" ]] || {
    echo "CannMedia is not mounted as a real directory; nothing was staged." >&2
    exit 1
}
volume_uuid="$(
    /usr/sbin/diskutil info -plist "${VOLUME_ROOT}" 2>/dev/null \
        | /usr/bin/plutil -extract VolumeUUID raw -o - - 2>/dev/null
)" || {
    echo "Could not read CannMedia volume identity; nothing was staged." >&2
    exit 1
}
[[ "${volume_uuid}" == "${EXPECTED_VOLUME_UUID}" ]] || {
    echo "CannMedia UUID mismatch; refusing to stage the worker service." >&2
    exit 1
}
[[ -f "${WRAPPER}" && ! -L "${WRAPPER}" ]] || {
    echo "Worker wrapper is missing or unsafe: ${WRAPPER}" >&2
    exit 1
}
[[ -x "${LAUNCHER}" && ! -L "${LAUNCHER}" ]] || {
    echo "Install Meeting Archive Worker.app and grant its CannMedia access first." >&2
    exit 1
}

# Keep startup diagnostics private and bounded to the current and previous install.
if [[ -e "${LOG_DIRECTORY}" || -L "${LOG_DIRECTORY}" ]]; then
    [[ -d "${LOG_DIRECTORY}" && ! -L "${LOG_DIRECTORY}" ]] || {
        echo "Worker log directory is unsafe: ${LOG_DIRECTORY}" >&2
        exit 1
    }
else
    /bin/mkdir -p "${LOG_DIRECTORY}"
fi
/bin/chmod 700 "${LOG_DIRECTORY}"
if [[ -e "${STDERR_LOG}" || -L "${STDERR_LOG}" ]]; then
    [[ -f "${STDERR_LOG}" && ! -L "${STDERR_LOG}" ]] || {
        echo "Worker stderr log is unsafe: ${STDERR_LOG}" >&2
        exit 1
    }
fi
if [[ -e "${PREVIOUS_STDERR_LOG}" || -L "${PREVIOUS_STDERR_LOG}" ]]; then
    [[ -f "${PREVIOUS_STDERR_LOG}" && ! -L "${PREVIOUS_STDERR_LOG}" ]] || {
        echo "Previous worker stderr log is unsafe: ${PREVIOUS_STDERR_LOG}" >&2
        exit 1
    }
fi
if [[ -f "${STDERR_LOG}" ]]; then
    /bin/mv -f "${STDERR_LOG}" "${PREVIOUS_STDERR_LOG}"
fi
: >"${STDERR_LOG}"
/bin/chmod 600 "${STDERR_LOG}"

/bin/mkdir -p "${AGENT_DIRECTORY}"
temporary="$(/usr/bin/mktemp "${AGENT_DIRECTORY}/.${LABEL}.XXXXXX")"
trap '/bin/rm -f "${temporary}"' EXIT
/bin/cat >"${temporary}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${LAUNCHER}</string>
        <string>--worker</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>${STDERR_LOG}</string>
</dict>
</plist>
PLIST
/bin/chmod 600 "${temporary}"
/bin/mv -f "${temporary}" "${PLIST}"
trap - EXIT

echo "Staged ${PLIST}. Startup errors will be written to ${STDERR_LOG}. No credentials were changed."
if [[ "${enable}" != true ]]; then
    echo "The service was not enabled."
    echo "Review it, then enable explicitly with: $0 --enable"
    exit 0
fi

domain="gui/$(/usr/bin/id -u)"
/bin/launchctl enable "${domain}/${LABEL}"
if /bin/launchctl print "${domain}/${LABEL}" >/dev/null 2>&1; then
    /bin/launchctl kickstart -k "${domain}/${LABEL}"
else
    /bin/launchctl bootstrap "${domain}" "${PLIST}"
fi
echo "Enabled ${LABEL}. The worker will retry safely if the volume or credentials are unavailable."
