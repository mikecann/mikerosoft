#!/usr/bin/env python3
"""
macOS / POSIX transcribe: ffmpeg (PATH) + faster-whisper (pip).

Usage:
  transcribe <video_file> [--cpu] [--model <name>]

Writes <video_basename>.srt next to the input file (same as transcribe.bat).

Env:
  TRANSCRIBE_MODEL  Whisper model id (default: small). Examples: base, small, medium, large-v3.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def die(msg: str, code: int = 1) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(code)


def seconds_to_srt_ts(sec: float) -> str:
    if sec < 0:
        sec = 0.0
    h = int(sec // 3600)
    m = int((sec % 3600) // 60)
    s = sec % 60
    whole = int(s)
    ms = int(round((s - whole) * 1000))
    if ms >= 1000:
        ms = 0
        whole += 1
        if whole >= 60:
            whole = 0
            m += 1
    return f"{h:02d}:{m:02d}:{whole:02d},{ms:03d}"


def write_srt(path: Path, segments) -> None:
    blocks: list[tuple[float, float, str]] = []
    for seg in segments:
        text = (seg.text or "").strip()
        if not text:
            continue
        blocks.append((float(seg.start), float(seg.end), text))

    lines: list[str] = []
    for i, (start_sec, end_sec, text) in enumerate(blocks, start=1):
        start = seconds_to_srt_ts(start_sec)
        end = seconds_to_srt_ts(end_sec)
        lines.append(f"{i}\n{start} --> {end}\n{text}\n")
    path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")


def require_ffmpeg() -> str:
    exe = shutil.which("ffmpeg")
    if not exe:
        die(
            "ffmpeg not found on PATH. Install it first, e.g.\n"
            "  brew install ffmpeg\n",
        )
    return exe


def has_audio_stream(*, ffmpeg: str, video: Path) -> bool:
    ffprobe = shutil.which("ffprobe")
    if not ffprobe:
        ffprobe_bin = Path(ffmpeg).resolve().parent / "ffprobe"
        if ffprobe_bin.is_file():
            ffprobe = str(ffprobe_bin)
        else:
            return True
    cmd = [
        ffprobe,
        "-v",
        "error",
        "-show_entries",
        "stream=codec_type",
        "-of",
        "csv=p=0",
        str(video),
    ]
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True)
    except subprocess.CalledProcessError:
        return False
    types = {line.strip() for line in out.splitlines() if line.strip()}
    return "audio" in types


def extract_wav(*, ffmpeg: str, video: Path, wav: Path) -> None:
    if not has_audio_stream(ffmpeg=ffmpeg, video=video):
        die(
            f"No audio stream in: {video}\n"
            "Transcribe needs at least one audio track. Re-encode with audio, e.g.\n"
            "  ffmpeg -y -i video.mp4 -i narration.m4a -map 0:v -map 1:a -c:v copy -c:a aac -shortest out.mp4\n",
        )

    cmd = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(video),
        "-vn",
        "-acodec",
        "pcm_s16le",
        "-ar",
        "16000",
        "-ac",
        "1",
        str(wav),
    ]
    try:
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError:
        die(
            f"ffmpeg failed to extract audio from: {video}\n"
            "If this file is video-only, add a narration track first (see message above).\n",
        )


def pick_device(force_cpu: bool) -> tuple[str, str]:
    if force_cpu:
        return "cpu", "int8"
    try:
        import torch

        if torch.cuda.is_available():
            return "cuda", "float16"
    except ImportError:
        pass
    return "cpu", "int8"


def main() -> None:
    parser = argparse.ArgumentParser(description="Transcribe video to SRT (macOS / POSIX)")
    parser.add_argument("video_file", help="Path to video or audio file")
    parser.add_argument("--cpu", action="store_true", help="Force CPU inference")
    parser.add_argument(
        "--model",
        default=os.environ.get("TRANSCRIBE_MODEL", "small"),
        help="Whisper model name (default: env TRANSCRIBE_MODEL or small)",
    )
    args = parser.parse_args()

    video = Path(args.video_file).expanduser().resolve()
    if not video.exists():
        die(f"Error: File not found: {video}")

    try:
        from faster_whisper import WhisperModel
    except ImportError:
        die(
            "faster-whisper is not installed.\n"
            "  python3 -m pip install faster-whisper\n"
            "Or run: bash tools/transcribe/deps.sh\n",
        )

    ffmpeg = require_ffmpeg()
    device, compute_type = pick_device(args.cpu)
    model_name = (args.model or "small").strip()

    out_srt = video.with_suffix(".srt")

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        wav_path = Path(tmp.name)

    try:
        print("Extracting audio from video...")
        extract_wav(ffmpeg=ffmpeg, video=video, wav=wav_path)

        print(f"Transcribing audio (device: {device}, model: {model_name})...")
        model = WhisperModel(model_name, device=device, compute_type=compute_type)
        segments_gen, _info = model.transcribe(
            str(wav_path),
            beam_size=5,
            vad_filter=True,
        )
        segments = list(segments_gen)

        write_srt(out_srt, segments)

        print()
        print("========================================")
        print("Transcription:")
        print("========================================")
        print(out_srt.read_text(encoding="utf-8", errors="replace").rstrip())
        print()
        print("========================================")
        print(f"Transcription saved to: {out_srt}")
    finally:
        try:
            wav_path.unlink(missing_ok=True)
        except OSError:
            pass


if __name__ == "__main__":
    main()
