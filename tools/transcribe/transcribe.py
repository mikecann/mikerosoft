#!/usr/bin/env python3
"""
Python transcribe path: ffmpeg + faster-whisper (pip), with optional pyannote diarization.

Usage:
  transcribe <video_file> [--cpu] [--model <name>] [--diarize]

Writes <video_basename>.srt next to the input file (same as transcribe.bat).

Env:
  TRANSCRIBE_MODEL  Whisper model id (default: small). Examples: base, small, medium, large-v3.
  HF_TOKEN or HUGGINGFACE_TOKEN  Required for --diarize unless --hf-token is passed.
  TRANSCRIBE_DIARIZATION_MODEL  pyannote model id (default: pyannote/speaker-diarization-community-1).
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import warnings
import wave
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class TranscriptSegment:
    start: float
    end: float
    text: str
    speaker: str | None = None


@dataclass(frozen=True)
class SpeakerTurn:
    start: float
    end: float
    speaker: str


def die(msg: str, code: int = 1) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(code)


def load_dotenv_file(path: Path) -> None:
    if not path.is_file():
        return
    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


def load_repo_dotenv() -> None:
    load_dotenv_file(Path(__file__).resolve().parents[2] / ".env")


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


def to_transcript_segment(segment) -> TranscriptSegment | None:
    text = (segment.text or "").strip()
    if not text:
        return None
    return TranscriptSegment(
        start=float(segment.start),
        end=float(segment.end),
        text=text,
        speaker=getattr(segment, "speaker", None),
    )


def assign_speakers_to_segments(segments, turns: list[SpeakerTurn]) -> list[TranscriptSegment]:
    assigned: list[TranscriptSegment] = []
    for seg in segments:
        transcript_segment = to_transcript_segment(seg)
        if transcript_segment is None:
            continue
        speaker = speaker_for_segment(transcript_segment, turns)
        assigned.append(
            TranscriptSegment(
                transcript_segment.start,
                transcript_segment.end,
                transcript_segment.text,
                speaker,
            ),
        )
    return assigned


def speaker_for_segment(segment: TranscriptSegment, turns: list[SpeakerTurn]) -> str | None:
    best_speaker: str | None = None
    best_overlap = 0.0
    for turn in turns:
        overlap = max(0.0, min(segment.end, turn.end) - max(segment.start, turn.start))
        if overlap > best_overlap:
            best_overlap = overlap
            best_speaker = turn.speaker
    return best_speaker


def resolve_huggingface_token(explicit_token: str | None) -> str | None:
    if explicit_token:
        return explicit_token
    return os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_TOKEN")


def speaker_turns_from_pyannote_output(output) -> list[SpeakerTurn]:
    annotation = (
        getattr(output, "exclusive_speaker_diarization", None)
        or getattr(output, "speaker_diarization", None)
        or output
    )

    turns: list[SpeakerTurn] = []
    try:
        for turn, speaker in annotation:
            turns.append(SpeakerTurn(float(turn.start), float(turn.end), str(speaker)))
        return turns
    except (TypeError, ValueError):
        pass

    if hasattr(annotation, "itertracks"):
        for turn, _track, speaker in annotation.itertracks(yield_label=True):
            turns.append(SpeakerTurn(float(turn.start), float(turn.end), str(speaker)))
        return turns

    die("Speaker diarization returned an unsupported result format.")


def load_wav_for_pyannote(wav_path: Path):
    try:
        import numpy as np
        import torch
    except ImportError:
        die(
            "Speaker diarization needs numpy and torch.\n"
            "Install them with:\n"
            "  python -m pip install numpy torch\n",
        )

    with wave.open(str(wav_path), "rb") as wav:
        channels = wav.getnchannels()
        sample_width = wav.getsampwidth()
        sample_rate = wav.getframerate()
        frame_count = wav.getnframes()
        frames = wav.readframes(frame_count)

    if sample_width != 2:
        die(f"Expected 16-bit PCM WAV for diarization, got sample width {sample_width}.")

    samples = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)

    waveform = torch.from_numpy(samples).unsqueeze(0)
    return {"waveform": waveform, "sample_rate": sample_rate}


def diarize_audio(
    *,
    wav_path: Path,
    hf_token: str | None,
    model_name: str,
    num_speakers: int | None,
    min_speakers: int | None,
    max_speakers: int | None,
) -> list[SpeakerTurn]:
    token = resolve_huggingface_token(hf_token)
    if not token:
        die(
            "Speaker diarization needs a Hugging Face token.\n"
            "Create one at https://hf.co/settings/tokens, accept the pyannote model terms, then set HF_TOKEN or pass --hf-token.\n",
        )

    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            from pyannote.audio import Pipeline
    except ImportError:
        die(
            "Speaker diarization needs pyannote.audio.\n"
            "Install it with:\n"
            "  python -m pip install pyannote.audio\n",
        )

    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            pipeline = Pipeline.from_pretrained(model_name, token=token)
    except Exception as exc:
        die(
            f"Could not load diarization model: {model_name}\n"
            "If this is a 403 or gated repo error, open the model page in the same Hugging Face account as your token and request/accept access:\n"
            f"  https://hf.co/{model_name}\n"
            "Then retry Transcribe with Speakers.\n"
            f"\nOriginal error: {exc}\n",
        )
    kwargs: dict[str, int] = {}
    if num_speakers is not None:
        kwargs["num_speakers"] = num_speakers
    if min_speakers is not None:
        kwargs["min_speakers"] = min_speakers
    if max_speakers is not None:
        kwargs["max_speakers"] = max_speakers

    return speaker_turns_from_pyannote_output(pipeline(load_wav_for_pyannote(wav_path), **kwargs))


def write_srt(path: Path, segments) -> None:
    blocks: list[TranscriptSegment] = []
    for seg in segments:
        transcript_segment = to_transcript_segment(seg)
        if transcript_segment is not None:
            blocks.append(transcript_segment)

    lines: list[str] = []
    for i, segment in enumerate(blocks, start=1):
        start = seconds_to_srt_ts(segment.start)
        end = seconds_to_srt_ts(segment.end)
        text = segment.text
        if segment.speaker:
            text = f"[{segment.speaker}] {text}"
        lines.append(f"{i}\n{start} --> {end}\n{text}\n")
    path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")


def require_ffmpeg() -> str:
    exedir = os.environ.get("EXEDIR")
    if exedir:
        windows_ffmpeg = Path(exedir) / "ffmpeg.exe"
        if windows_ffmpeg.is_file():
            return str(windows_ffmpeg)

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
    warnings.filterwarnings(
        "ignore",
        message=".*degrees of freedom is <= 0.*",
        category=UserWarning,
    )
    load_repo_dotenv()

    parser = argparse.ArgumentParser(description="Transcribe video to SRT")
    parser.add_argument("video_file", help="Path to video or audio file")
    parser.add_argument("--cpu", action="store_true", help="Force CPU inference")
    parser.add_argument(
        "--diarize",
        action="store_true",
        help="Label transcript lines with speaker IDs using pyannote.audio",
    )
    parser.add_argument(
        "--hf-token",
        default=None,
        help="Hugging Face token for pyannote diarization (or set HF_TOKEN)",
    )
    parser.add_argument(
        "--model",
        default=os.environ.get("TRANSCRIBE_MODEL", "small"),
        help="Whisper model name (default: env TRANSCRIBE_MODEL or small)",
    )
    parser.add_argument(
        "--diarization-model",
        default=os.environ.get(
            "TRANSCRIBE_DIARIZATION_MODEL",
            "pyannote/speaker-diarization-community-1",
        ),
        help="pyannote diarization model name",
    )
    parser.add_argument("--num-speakers", type=int, default=None, help="Exact speaker count")
    parser.add_argument("--min-speakers", type=int, default=None, help="Minimum speaker count")
    parser.add_argument("--max-speakers", type=int, default=None, help="Maximum speaker count")
    args = parser.parse_args()
    if args.num_speakers is not None and (
        args.min_speakers is not None or args.max_speakers is not None
    ):
        die("Use --num-speakers or --min-speakers/--max-speakers, not both.")

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

        if args.diarize:
            print(f"Running speaker diarization (model: {args.diarization_model})...")
            speaker_turns = diarize_audio(
                wav_path=wav_path,
                hf_token=args.hf_token,
                model_name=args.diarization_model,
                num_speakers=args.num_speakers,
                min_speakers=args.min_speakers,
                max_speakers=args.max_speakers,
            )
            segments = assign_speakers_to_segments(segments, speaker_turns)

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
