#!/bin/bash
# Run the private viewer only when the verified CannMedia volume is mounted.

set -euo pipefail
umask 077

readonly EXPECTED_VOLUME_UUID="5CCB1D81-5A98-4C4A-9E2C-3E10B23F1B46"
readonly VOLUME_ROOT="/Volumes/CannMedia"
readonly ARCHIVE_ROOT="${VOLUME_ROOT}/MeetingArchive/meetings"
readonly RUNTIME_ROOT="${VOLUME_ROOT}/MeetingArchive/runtime"
readonly WORKER_ROOT="${RUNTIME_ROOT}/worker"
readonly PYTHON="${RUNTIME_ROOT}/venv/bin/python"
readonly DATABASE="${VOLUME_ROOT}/MeetingArchive/worker.sqlite"
readonly LISTEN_HOST="127.0.0.1"
readonly ALLOWED_LOGIN="mike.cann@gmail.com"

fail() {
    echo "Meeting Archive viewer: $1" >&2
    exit 1
}

[[ -d "${VOLUME_ROOT}" && ! -L "${VOLUME_ROOT}" ]] \
    || fail "CannMedia is not mounted as a real directory; viewer remains stopped."
volume_uuid="$(
    /usr/sbin/diskutil info -plist "${VOLUME_ROOT}" 2>/dev/null \
        | /usr/bin/plutil -extract VolumeUUID raw -o - - 2>/dev/null
)" || fail "Could not read CannMedia volume identity; viewer remains stopped."
[[ "${volume_uuid}" == "${EXPECTED_VOLUME_UUID}" ]] \
    || fail "CannMedia UUID mismatch; viewer refuses internal-volume fallback."

[[ -d "${ARCHIVE_ROOT}" && ! -L "${ARCHIVE_ROOT}" ]] \
    || fail "Meetings archive root is missing or unsafe."
[[ -d "${WORKER_ROOT}" && ! -L "${WORKER_ROOT}" ]] \
    || fail "Worker source is missing or unsafe."
[[ -x "${PYTHON}" ]] \
    || fail "Dedicated Python environment is missing or unsafe."
[[ -f "${DATABASE}" && ! -L "${DATABASE}" ]] \
    || fail "Worker database is missing or unsafe."

# The viewer never needs model or publication credentials. Explicitly remove
# them so a future parent process cannot leak them into this HTTP service.
unset HF_TOKEN HUGGING_FACE_HUB_TOKEN MEETING_ARCHIVE_NOTION_TOKEN
unset MEETING_ARCHIVE_ALLOW_TRANSCRIPTION_WITHOUT_DIARIZATION
export PATH="${RUNTIME_ROOT}/venv/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PYTHONNOUSERSITE=1

cd "${WORKER_ROOT}"
exec /usr/bin/nice -n 10 "${PYTHON}" -m meeting_archive_worker.viewer \
    --archive-root "${ARCHIVE_ROOT}" \
    --db "${DATABASE}" \
    --host "${LISTEN_HOST}" \
    --port 8765 \
    --allowed-login "${ALLOWED_LOGIN}" \
    --max-threads 4
