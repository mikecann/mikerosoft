#!/bin/bash
# Runtime entry point for Bruce. This script must reject the wrong volume
# before Python can open SQLite or create any archive path.

set -euo pipefail
umask 077

readonly EXPECTED_VOLUME_UUID="5CCB1D81-5A98-4C4A-9E2C-3E10B23F1B46"
readonly VOLUME_ROOT="/Volumes/CannMedia"
readonly ARCHIVE_ROOT="${VOLUME_ROOT}/MeetingArchive"
readonly RUNTIME_ROOT="${ARCHIVE_ROOT}/runtime"
readonly PYTHON="${RUNTIME_ROOT}/venv/bin/python"
readonly WORKER_ROOT="${RUNTIME_ROOT}/worker"
readonly DATABASE="${ARCHIVE_ROOT}/worker.sqlite"
readonly MODEL_ROOT="${RUNTIME_ROOT}/models"
readonly CACHE_ROOT="${RUNTIME_ROOT}/cache"
readonly SCRATCH_ROOT="${RUNTIME_ROOT}/tmp"

log_error() {
    /usr/bin/logger -t meeting-archive-worker -- "$1"
}

fail() {
    printf 'Meeting Archive worker: %s\n' "$1" >&2
    log_error "$1"
    exit 1
}

[[ -d "${VOLUME_ROOT}" && ! -L "${VOLUME_ROOT}" ]] \
    || fail "CannMedia is not mounted as a real directory; worker remains stopped."

volume_uuid="$(
    /usr/sbin/diskutil info -plist "${VOLUME_ROOT}" 2>/dev/null \
        | /usr/bin/plutil -extract VolumeUUID raw -o - - 2>/dev/null
)" || fail "Could not read CannMedia volume identity; worker remains stopped."
[[ "${volume_uuid}" == "${EXPECTED_VOLUME_UUID}" ]] \
    || fail "CannMedia volume UUID mismatch; worker refuses internal-volume fallback."

for required_directory in \
    "${ARCHIVE_ROOT}" \
    "${RUNTIME_ROOT}" \
    "${WORKER_ROOT}" \
    "${MODEL_ROOT}" \
    "${CACHE_ROOT}" \
    "${SCRATCH_ROOT}"
do
    [[ -d "${required_directory}" && ! -L "${required_directory}" ]] \
        || fail "Required external worker directory is missing or unsafe: ${required_directory}"
done
[[ -x "${PYTHON}" ]] || fail "Dedicated Meeting Archive Python is missing: ${PYTHON}"
[[ -f "${WORKER_ROOT}/worker.py" && ! -L "${WORKER_ROOT}/worker.py" ]] \
    || fail "Meeting Archive worker source is missing or unsafe."
if [[ -e "${DATABASE}" || -L "${DATABASE}" ]]; then
    [[ -f "${DATABASE}" && ! -L "${DATABASE}" ]] \
        || fail "Worker database path is not a regular external-volume file."
fi

# The Python entry point loads the owner-only credential file into memory.
# Bruce's locked login Keychain cannot serve an unattended SSH/login worker.
# No token is passed in argv, echoed, or placed in the LaunchAgent plist.
unset HF_TOKEN MEETING_ARCHIVE_NOTION_TOKEN || true

export MEETING_ARCHIVE_NOTION_DATA_SOURCE="fe4b72d1-b303-42ba-a812-3349655746c5"
export MEETING_ARCHIVE_PLAYBACK_BASE_URL="https://bruce.tail9ef766.ts.net:10443"
export HF_HOME="${MODEL_ROOT}"
export XDG_CACHE_HOME="${CACHE_ROOT}"
export MEETING_ARCHIVE_SCRATCH="${SCRATCH_ROOT}"
export TMPDIR="${SCRATCH_ROOT}"
export TMP="${SCRATCH_ROOT}"
export TEMP="${SCRATCH_ROOT}"
export PATH="${RUNTIME_ROOT}/venv/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export DO_NOT_TRACK=1
export HF_HUB_DISABLE_TELEMETRY=1
export PYANNOTE_METRICS_ENABLED=0
export TOKENIZERS_PARALLELISM=false
export OMP_NUM_THREADS=2
export MKL_NUM_THREADS=2
export MEETING_ARCHIVE_TORCH_THREADS=2
export MEETING_ARCHIVE_WHISPER_CPU_THREADS=2
export PYTHONUNBUFFERED=1
unset MEETING_ARCHIVE_ALLOW_TRANSCRIPTION_WITHOUT_DIARIZATION || true

cd "${WORKER_ROOT}"
exec /usr/bin/nice -n 10 "${PYTHON}" -m meeting_archive_worker.credentials \
    --db "${DATABASE}" \
    --poll-seconds 15
