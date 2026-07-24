#!/usr/bin/env python3
"""Convert a ScreenCaptureKit recording to MP3, transcribe it, and diarize speakers."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
import warnings
import wave
from pathlib import Path
from typing import NamedTuple


class SpeakerTurn(NamedTuple):
    start: float
    end: float
    speaker: str


def executable(name: str) -> str:
    found = shutil.which(name)
    if found:
        return found
    for prefix in ("/opt/homebrew/bin", "/usr/local/bin"):
        candidate = Path(prefix) / name
        if candidate.is_file():
            return str(candidate)
    raise RuntimeError(f"{name} is not installed. Run tools/record-meeting/setup_mac.sh.")


def run(command: list[str]) -> None:
    subprocess.run(command, check=True)


def audio_stream_count(input_path: Path) -> int:
    try:
        ffprobe = executable("ffprobe")
    except RuntimeError:
        # Some standalone ffmpeg distributions omit ffprobe. Its input summary
        # still exposes every audio stream, so keep the converter usable.
        result = subprocess.run(
            [executable("ffmpeg"), "-hide_banner", "-i", str(input_path)],
            capture_output=True,
            text=True,
        )
        return len(re.findall(r"Stream #\S+: Audio:", result.stderr))

    result = subprocess.run(
        [
            ffprobe,
            "-v",
            "error",
            "-select_streams",
            "a",
            "-show_entries",
            "stream=index",
            "-of",
            "json",
            str(input_path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return len(json.loads(result.stdout).get("streams", []))


def mix_filter(stream_count: int) -> tuple[list[str], str | None]:
    if stream_count < 1:
        raise RuntimeError("The recording contains no audio streams.")
    if stream_count == 1:
        return ["-map", "0:a:0"], None
    inputs = "".join(f"[0:a:{index}]" for index in range(stream_count))
    label = "[a]"
    return [
        "-filter_complex",
        f"{inputs}amix=inputs={stream_count}:duration=longest:normalize=0{label}",
        "-map",
        label,
    ], label


def convert_to_mp3(input_path: Path, output_path: Path) -> None:
    stream_count = audio_stream_count(input_path)
    mapping, _ = mix_filter(stream_count)
    run(
        [
            executable("ffmpeg"),
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(input_path),
            *mapping,
            "-vn",
            "-codec:a",
            "libmp3lame",
            "-q:a",
            "2",
            str(output_path),
        ],
    )


def extract_wav(input_path: Path, wav_path: Path) -> None:
    run(
        [
            executable("ffmpeg"),
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(input_path),
            "-vn",
            "-acodec",
            "pcm_s16le",
            "-ar",
            "16000",
            "-ac",
            "1",
            str(wav_path),
        ],
    )


def load_wav(wav_path: Path):
    import numpy as np
    import torch

    with wave.open(str(wav_path), "rb") as audio:
        channels = audio.getnchannels()
        if audio.getsampwidth() != 2:
            raise RuntimeError("Expected a 16-bit WAV for speaker detection.")
        sample_rate = audio.getframerate()
        samples = np.frombuffer(
            audio.readframes(audio.getnframes()),
            dtype=np.int16,
        ).astype(np.float32) / 32768.0
    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)
    return {"waveform": torch.from_numpy(samples).unsqueeze(0), "sample_rate": sample_rate}


def speaker_turns(output) -> list[SpeakerTurn]:
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


def diarize(wav_path: Path, token: str) -> list[SpeakerTurn]:
    model_name = os.environ.get(
        "RECORD_MEETING_DIARIZATION_MODEL",
        "pyannote/speaker-diarization-community-1",
    )
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        from pyannote.audio import Pipeline

        pipeline = Pipeline.from_pretrained(model_name, token=token)
        turns = speaker_turns(pipeline(load_wav(wav_path)))
    if not turns:
        raise RuntimeError("Speaker detection finished without finding any speakers.")
    return turns


def assign_speaker(start: float, end: float, turns: list[SpeakerTurn]) -> str | None:
    best_speaker = None
    best_overlap = 0.0
    for turn in turns:
        overlap = max(0.0, min(end, turn.end) - max(start, turn.start))
        if overlap > best_overlap:
            best_overlap = overlap
            best_speaker = turn.speaker
    return best_speaker


def sample_turns(
    turns: list[SpeakerTurn],
    maximum_duration: float = 8,
) -> dict[str, tuple[float, float]]:
    selected: dict[str, tuple[float, float]] = {}
    for turn in turns:
        duration = min(maximum_duration, max(0.0, turn.end - turn.start))
        current = selected.get(turn.speaker)
        if duration >= 0.5 and (current is None or duration > current[1]):
            selected[turn.speaker] = (turn.start, duration)
    return selected


def write_speaker_samples(
    audio_path: Path,
    turns: list[SpeakerTurn],
    output_directory: Path,
    stem: str,
) -> dict[str, Path]:
    paths: dict[str, Path] = {}
    for speaker, (start, duration) in sample_turns(turns).items():
        safe_speaker = "".join(character for character in speaker if character.isalnum() or character in "_-")
        path = output_directory / f"{stem}.sample-{safe_speaker}.mp3"
        run(
            [
                executable("ffmpeg"),
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-ss",
                f"{start:.3f}",
                "-t",
                f"{duration:.3f}",
                "-i",
                str(audio_path),
                "-codec:a",
                "libmp3lame",
                "-q:a",
                "4",
                str(path),
            ],
        )
        paths[speaker] = path
    return paths


def process(input_path: Path, output_directory: Path, stem: str, model_name: str) -> Path:
    token = os.environ.get("HF_TOKEN", "").strip()
    if not token:
        raise RuntimeError(
            "Speaker detection needs a Hugging Face token. Open Preferences in "
            "Record Meeting, add the token, and accept access to "
            "pyannote/speaker-diarization-community-1 on Hugging Face.",
        )

    try:
        from faster_whisper import WhisperModel
    except ImportError as error:
        raise RuntimeError(
            "The transcription environment is missing. Run tools/record-meeting/setup_mac.sh.",
        ) from error

    output_directory.mkdir(parents=True, exist_ok=True)
    audio_path = output_directory / f"{stem}.mp3"
    transcript_path = output_directory / f"{stem}.transcript.json"
    convert_to_mp3(input_path, audio_path)

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as temporary:
        wav_path = Path(temporary.name)
    try:
        extract_wav(audio_path, wav_path)
        turns = diarize(wav_path, token)
        model = WhisperModel(model_name, device="cpu", compute_type="int8")
        generated, _ = model.transcribe(
            str(wav_path),
            beam_size=5,
            vad_filter=True,
        )
        segments = []
        for segment in generated:
            text = (segment.text or "").strip()
            if text:
                segments.append(
                    {
                        "start": float(segment.start),
                        "end": float(segment.end),
                        "text": text,
                        "speaker": assign_speaker(float(segment.start), float(segment.end), turns),
                    },
                )
        samples = write_speaker_samples(audio_path, turns, output_directory, stem)
        speakers = sorted({turn.speaker for turn in turns})
        payload = {
            "segments": segments,
            "speakers": [
                {"id": speaker, "sample_path": str(samples.get(speaker, ""))}
                for speaker in speakers
            ],
        }
        transcript_path.write_text(
            json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        return transcript_path
    finally:
        wav_path.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--stem", required=True)
    parser.add_argument("--model", default="large-v3")
    arguments = parser.parse_args()
    try:
        transcript_path = process(
            arguments.input.expanduser().resolve(),
            arguments.output_dir.expanduser().resolve(),
            arguments.stem,
            arguments.model,
        )
        print(f"Transcript data saved to {transcript_path}")
    except Exception as error:
        raise SystemExit(f"Record Meeting processing failed: {error}") from error


if __name__ == "__main__":
    main()
