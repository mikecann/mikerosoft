#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORT_DIR="$HOME/Library/Application Support/Record Meeting"
VENV_DIR="$SUPPORT_DIR/venv"

echo "[record-meeting] Checking dependencies..."

if command -v ffmpeg >/dev/null 2>&1; then
  echo "  OK  ffmpeg"
  if ! command -v ffprobe >/dev/null 2>&1; then
    echo "  NOTE  ffprobe is absent; the processor will use its ffmpeg fallback."
  fi
elif command -v brew >/dev/null 2>&1; then
  echo "  Installing ffmpeg with Homebrew..."
  brew install ffmpeg
else
  echo "  MISSING  ffmpeg. Install it from https://ffmpeg.org and retry."
  exit 1
fi

mkdir -p "$SUPPORT_DIR"
if [[ ! -x "$VENV_DIR/bin/python3" ]]; then
  echo "  Creating transcription environment..."
  python3 -m venv "$VENV_DIR"
fi

echo "  Installing/updating faster-whisper and pyannote.audio..."
"$VENV_DIR/bin/python3" -m pip install --upgrade pip
"$VENV_DIR/bin/python3" -m pip install --upgrade faster-whisper pyannote.audio

RECORD_MEETING_BUILD_CONFIGURATION=release bash "$SCRIPT_DIR/build-app.sh"

echo ""
echo "Record Meeting is installed at ~/Applications/Record Meeting.app"
echo "Launch it with: record-meeting"
echo "Before the first transcription, add a Hugging Face token in Preferences."
