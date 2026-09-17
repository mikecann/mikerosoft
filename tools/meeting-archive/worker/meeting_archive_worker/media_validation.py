"""Bounded structural and full-decode checks for finalized media files."""

from __future__ import annotations

import json
import math
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

from .manifest import VerifiedManifest


class MediaValidationError(RuntimeError):
    """A finalized media file is missing usable streams or cannot be decoded."""


_EXPECTED_STREAM = {
    "video": "video",
    "microphone_audio": "audio",
    "incoming_audio": "audio",
}


def _executable(name: str) -> str:
    found = shutil.which(name)
    if found:
        return found
    for root in (Path("/opt/homebrew/bin"), Path("/usr/local/bin"), Path.home() / ".local/bin"):
        candidate = root / name
        if candidate.is_file():
            return str(candidate)
    raise MediaValidationError(f"{name} is required for finalized media validation.")


def _positive_float(value: Any) -> float | None:
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result if math.isfinite(result) and result > 0 else None


def _probe(path: Path, ffprobe: str, timeout: float) -> dict[str, Any]:
    try:
        completed = subprocess.run(
            [
                ffprobe,
                "-v",
                "error",
                "-show_entries",
                "format=duration,start_time:stream=codec_type,duration,start_time",
                "-of",
                "json",
                str(path),
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        raise MediaValidationError(f"ffprobe timed out while validating {path.name}.") from error
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or "").strip()[-1000:]
        raise MediaValidationError(
            f"ffprobe could not read {path.name}: {detail or 'invalid media container'}",
        ) from error
    try:
        value = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise MediaValidationError(f"ffprobe returned invalid JSON for {path.name}.") from error
    if not isinstance(value, dict):
        raise MediaValidationError(f"ffprobe returned invalid stream data for {path.name}.")
    return value


def _stream_duration(probe: dict[str, Any], expected_type: str, label: str) -> tuple[float, float]:
    streams = [
        stream
        for stream in probe.get("streams", [])
        if isinstance(stream, dict) and stream.get("codec_type") == expected_type
    ]
    if not streams:
        raise MediaValidationError(f"{label} has no {expected_type} stream.")
    format_data = probe.get("format") if isinstance(probe.get("format"), dict) else {}
    format_duration = _positive_float(format_data.get("duration"))
    durations = [_positive_float(stream.get("duration")) for stream in streams]
    duration = max((item for item in durations if item is not None), default=format_duration)
    if duration is None:
        raise MediaValidationError(f"{label} has no positive finite {expected_type} duration.")
    starts = []
    for stream in streams:
        try:
            start = float(stream.get("start_time", 0))
        except (TypeError, ValueError):
            start = 0.0
        if math.isfinite(start):
            starts.append(max(0.0, start))
    return duration, min(starts, default=0.0)


def _decode(path: Path, expected_type: str, ffmpeg: str, timeout: float) -> None:
    stream = "0:a:0" if expected_type == "audio" else "0:v:0"
    try:
        subprocess.run(
            [
                ffmpeg,
                "-nostdin",
                "-v",
                "error",
                "-xerror",
                "-threads",
                "1",
                "-i",
                str(path),
                "-map",
                stream,
                "-f",
                "null",
                "-",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        raise MediaValidationError(f"Full decode timed out while validating {path.name}.") from error
    except subprocess.CalledProcessError as error:
        detail = (error.stderr or "").strip()[-1000:]
        raise MediaValidationError(
            f"Full decode failed for {path.name}: {detail or 'corrupt media stream'}",
        ) from error


def validate_media_files(destination: Path, manifest: VerifiedManifest) -> dict[str, Any]:
    """Probe and fully decode every declared audio/video file before cleanup is allowed."""

    ffprobe = _executable("ffprobe")
    ffmpeg = _executable("ffmpeg")
    probe_timeout = float(os.environ.get("MEETING_ARCHIVE_FFPROBE_TIMEOUT_SECONDS", "30"))
    decode_timeout = float(os.environ.get("MEETING_ARCHIVE_MEDIA_DECODE_TIMEOUT_SECONDS", "7200"))
    if probe_timeout <= 0 or decode_timeout <= 0:
        raise MediaValidationError("Media validation timeouts must be positive.")

    results: list[dict[str, Any]] = []
    coverage = 0.0
    for item in manifest.files:
        expected_type = _EXPECTED_STREAM.get(item.kind)
        if expected_type is None:
            continue
        path = destination.joinpath(*item.path.split("/"))
        probe = _probe(path, ffprobe, probe_timeout)
        duration, start = _stream_duration(probe, expected_type, item.path)
        _decode(path, expected_type, ffmpeg, decode_timeout)
        coverage = max(coverage, start + duration)
        results.append(
            {
                "path": item.path,
                "kind": item.kind,
                "stream_type": expected_type,
                "duration_seconds": round(duration, 6),
                "start_time_seconds": round(start, 6),
                "full_decode": True,
            },
        )
    if not results:
        raise MediaValidationError("The manifest contains no declared audio or video media.")

    claimed_duration = float(manifest.metadata["duration_seconds"])
    tolerance = min(15.0, max(3.0, claimed_duration * 0.005))
    if claimed_duration > 0 and coverage + tolerance < claimed_duration:
        raise MediaValidationError(
            "Finalized media covers only "
            f"{coverage:.3f}s of the claimed {claimed_duration:.3f}s meeting duration "
            f"(tolerance {tolerance:.3f}s).",
        )
    return {
        "status": "passed",
        "validator_version": 1,
        "full_decode": True,
        "claimed_duration_seconds": claimed_duration,
        "coverage_duration_seconds": round(coverage, 6),
        "coverage_tolerance_seconds": round(tolerance, 6),
        "files": results,
    }
