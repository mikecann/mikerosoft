#!/bin/bash
# Stage Bruce's private-viewer LaunchAgent. Loading it requires explicit --enable.

set -euo pipefail
umask 077

readonly LABEL="com.mikerosoft.meeting-archive.viewer"
readonly EXPECTED_VOLUME_UUID="5CCB1D81-5A98-4C4A-9E2C-3E10B23F1B46"
readonly VOLUME_ROOT="/Volumes/CannMedia"
readonly RUNTIME_ROOT="${VOLUME_ROOT}/MeetingArchive/runtime"
readonly WRAPPER="${RUNTIME_ROOT}/worker/run-viewer-bruce.sh"
# Share the worker app's drive-consent identity, not a launchd-owned shell.
readonly LAUNCHER="${HOME}/Applications/Meeting Archive Worker.app/Contents/MacOS/meeting-archive-worker"
readonly AGENT_DIRECTORY="${HOME}/Library/LaunchAgents"
readonly PLIST="${AGENT_DIRECTORY}/${LABEL}.plist"

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
    echo "CannMedia UUID mismatch; refusing to stage the viewer service." >&2
    exit 1
}
[[ -f "${WRAPPER}" && ! -L "${WRAPPER}" ]] || {
    echo "Viewer wrapper is missing or unsafe: ${WRAPPER}" >&2
    exit 1
}
[[ -x "${LAUNCHER}" && ! -L "${LAUNCHER}" ]] || {
    echo "Install Meeting Archive Worker.app and grant its CannMedia access first." >&2
    exit 1
}

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
        <string>--viewer</string>
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
    <string>/dev/null</string>
</dict>
</plist>
PLIST
/bin/chmod 600 "${temporary}"
/bin/mv -f "${temporary}" "${PLIST}"
trap - EXIT

echo "Staged owner-only ${PLIST}. Tailscale Serve configuration was not changed."
if [[ "${enable}" != true ]]; then
    echo "The viewer was not enabled."
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
echo "Enabled ${LABEL} on localhost:8765. Tailscale Serve remains unchanged."
