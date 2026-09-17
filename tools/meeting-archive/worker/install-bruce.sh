#!/usr/bin/env bash
set -euo pipefail
ROOT="${MEETING_ARCHIVE_ROOT:-/Volumes/CannMedia/MeetingArchive}"
EXPECTED_VOLUME="${MEETING_ARCHIVE_VOLUME_UUID:-5CCB1D81-5A98-4C4A-9E2C-3E10B23F1B46}"
PYTHON="${MEETING_ARCHIVE_PYTHON:-/opt/homebrew/bin/python3.13}"
SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTUAL_VOLUME="$(diskutil info -plist /Volumes/CannMedia | "$PYTHON" -c 'import plistlib,sys; print(plistlib.loads(sys.stdin.buffer.read()).get("VolumeUUID", ""))')"
if [[ "$ACTUAL_VOLUME" != "$EXPECTED_VOLUME" ]]; then
  echo "The expected CannMedia archive volume is not mounted. Nothing was installed." >&2
  exit 1
fi
umask 077
mkdir -p "$ROOT/meetings" "$ROOT/incoming" "$ROOT/runtime/worker" "$ROOT/runtime/models" "$ROOT/runtime/cache" "$ROOT/runtime/tmp" "$ROOT/logs"
if [[ "$SOURCE" != "$ROOT/runtime/worker" ]]; then
  /usr/bin/rsync -a --exclude='__pycache__' --exclude='.venv' "$SOURCE/" "$ROOT/runtime/worker/"
fi
bash "$ROOT/runtime/worker/vision/build.sh"
if [[ ! -x "$ROOT/runtime/venv/bin/python3" ]]; then "$PYTHON" -m venv "$ROOT/runtime/venv"; fi
export PIP_CACHE_DIR="$ROOT/runtime/cache/pip"
export TMPDIR="$ROOT/runtime/tmp"
"$ROOT/runtime/venv/bin/python3" -m pip install -r "$ROOT/runtime/worker/requirements.txt"
"$ROOT/runtime/venv/bin/python3" -m pip check
"$ROOT/runtime/venv/bin/python3" -c 'import faster_whisper, pyannote.audio; print("Worker model libraries import successfully")'
echo "Installed worker at $ROOT. No background service has been enabled yet."
