#!/usr/bin/env bash
# macOS / Linux: ffmpeg + faster-whisper for tools/transcribe/transcribe
set -euo pipefail

WITH_DIARIZE=0
if [[ "${1:-}" == "--with-diarize" ]]; then
  WITH_DIARIZE=1
fi

echo "[transcribe] Checking dependencies..."

if command -v ffmpeg >/dev/null 2>&1; then
  echo "  OK  ffmpeg ($(command -v ffmpeg))"
else
  echo "  MISSING  ffmpeg"
  if command -v brew >/dev/null 2>&1; then
    echo "  Installing via Homebrew..."
    brew install ffmpeg
  else
    echo "  Install ffmpeg (e.g. https://ffmpeg.org/download.html) and re-run."
    exit 1
  fi
fi

echo "  Installing Python package faster-whisper (user site ok)..."
python3 -m pip install --user -q "faster-whisper>=1.0.0"

if python3 -c "import faster_whisper" 2>/dev/null; then
  echo "  OK  faster-whisper import"
else
  echo "  FAILED  faster-whisper still not importable"
  exit 1
fi

if [[ "$WITH_DIARIZE" == "1" ]]; then
  echo "  Installing optional Python package pyannote.audio for --diarize..."
  python3 -m pip install --user -q "pyannote.audio"

  if python3 -c "import pyannote.audio" 2>/dev/null; then
    echo "  OK  pyannote.audio import"
  else
    echo "  FAILED  pyannote.audio still not importable"
    exit 1
  fi
else
  echo "  SKIP optional diarization deps. Run: bash tools/transcribe/deps.sh --with-diarize"
fi

echo ""
echo "Done. Default model is small; set TRANSCRIBE_MODEL=large-v3 for higher quality (larger download)."
echo "For --diarize, set HF_TOKEN after accepting the pyannote model terms on Hugging Face."
