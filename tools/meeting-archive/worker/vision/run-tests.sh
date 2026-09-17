#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || true)}"
[[ -n "$PYTHON_BIN" ]] || {
  echo "python3 is required to validate the optional OCR JSON fixture" >&2
  exit 1
}
"$SCRIPT_DIR/build.sh"

"$SCRIPT_DIR/meeting-label-ocr" --help | grep -Fq 'maximum 12'
set +e
"$SCRIPT_DIR/meeting-label-ocr" a b c d e f g h i j k l m >/dev/null 2>&1
too_many_status=$?
set -e
[[ "$too_many_status" -eq 64 ]] || {
  echo "Expected EX_USAGE for more than 12 frames, got $too_many_status" >&2
  exit 1
}

if [[ -n "${MEETING_ARCHIVE_VISION_OCR_FIXTURE:-}" ]]; then
  fixture="$MEETING_ARCHIVE_VISION_OCR_FIXTURE"
  [[ -f "$fixture" && ! -L "$fixture" ]] || {
    echo "OCR fixture must be a regular non-symlink image" >&2
    exit 1
  }
  output="$($SCRIPT_DIR/meeting-label-ocr "$fixture")"
  "$PYTHON_BIN" - "$fixture" "$output" <<'PY'
import json
import sys

fixture, raw = sys.argv[1:]
payload = json.loads(raw)
assert payload["schema_version"] == 1
assert len(payload["frames"]) == 1
assert payload["frames"][0]["path"] == fixture
assert isinstance(payload["frames"][0]["observations"], list)
PY
  echo "Actual Vision OCR fixture passed"
else
  echo "Skipped actual OCR fixture; set MEETING_ARCHIVE_VISION_OCR_FIXTURE to a local PNG to enable it"
fi

echo "Vision OCR helper contract tests passed"
