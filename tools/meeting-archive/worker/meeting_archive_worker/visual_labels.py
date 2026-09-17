"""Bounded, local-only OCR evidence from visible meeting participant labels.

The result is deliberately tentative. A name in a frame means only that the
known participant label was visible while a diarized speaker was talking. It
must never be treated as an automatic speaker identification.
"""

from __future__ import annotations

import json
import math
import os
import re
import shutil
import stat
import subprocess
import tempfile
import time
from collections import defaultdict
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


MAX_FRAMES = 12
MAX_FRAMES_PER_SPEAKER = 3
MAX_HELPER_OUTPUT_BYTES = 1024 * 1024
TOTAL_TIMEOUT_SECONDS = 20.0
FRAME_TIMEOUT_SECONDS = 3.0
MIN_OCR_CONFIDENCE = 0.5
FFMPEG_FALLBACKS = (
    Path("/opt/homebrew/bin/ffmpeg"),
    Path("/usr/local/bin/ffmpeg"),
)


def default_helper_path() -> Path:
    """Return the fixed helper location inside the deployed worker tree."""
    return Path(__file__).resolve().parents[1] / "vision" / "meeting-label-ocr"


DEFAULT_HELPER_PATH = default_helper_path()


def extract_visual_labels(
    video_path: Path,
    turns: Sequence[Mapping[str, Any]],
    candidate_names: Iterable[str],
    helper_path: Path | None = None,
) -> dict[str, list[dict[str, Any]]]:
    """Return tentative known-name evidence grouped by diarized speaker ID.

    Missing tools, failed frame reads, helper timeouts, and malformed OCR are
    intentionally non-fatal. Callers should not permanently cache an empty
    result because it is indistinguishable from a transient local tool failure.
    """
    video = Path(video_path)
    helper = Path(helper_path) if helper_path is not None else default_helper_path()
    ffmpeg = _find_ffmpeg()
    candidates = _candidate_names(candidate_names)
    samples = _sample_turns(turns)
    if (
        ffmpeg is None
        or not candidates
        or not samples
        or not _is_regular_file(video)
        or not _is_executable_regular_file(helper)
    ):
        return {}

    deadline = time.monotonic() + TOTAL_TIMEOUT_SECONDS
    with tempfile.TemporaryDirectory(prefix="meeting-visual-labels-") as temporary:
        root = Path(temporary)
        frames: list[tuple[Path, str, float]] = []
        for index, (speaker_id, timestamp) in enumerate(samples):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            frame = root / f"frame-{index:02d}.png"
            command = [
                ffmpeg,
                "-nostdin",
                "-hide_banner",
                "-loglevel",
                "error",
                "-ss",
                _format_timestamp(timestamp),
                "-i",
                str(video),
                "-frames:v",
                "1",
                "-vf",
                "scale=1920:-2:force_original_aspect_ratio=decrease",
                "-y",
                str(frame),
            ]
            try:
                result = subprocess.run(
                    command,
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=min(FRAME_TIMEOUT_SECONDS, remaining),
                )
            except (OSError, subprocess.TimeoutExpired):
                continue
            if result.returncode == 0 and _is_regular_file(frame):
                frames.append((frame, speaker_id, timestamp))

        remaining = deadline - time.monotonic()
        if not frames or remaining <= 0:
            return {}
        try:
            result = subprocess.run(
                [str(helper), *(str(frame) for frame, _, _ in frames)],
                check=False,
                capture_output=True,
                text=True,
                timeout=remaining,
            )
        except (OSError, subprocess.TimeoutExpired):
            return {}
        if result.returncode != 0 or len(result.stdout.encode("utf-8")) > MAX_HELPER_OUTPUT_BYTES:
            return {}
        try:
            payload = json.loads(result.stdout)
        except (json.JSONDecodeError, TypeError):
            return {}

        return _evidence_from_ocr(payload, frames, candidates)


def _sample_turns(turns: Sequence[Mapping[str, Any]]) -> list[tuple[str, float]]:
    grouped: dict[str, list[float]] = {}
    first_seen: list[str] = []
    valid_turns: list[tuple[float, str, float]] = []
    for turn in turns:
        try:
            speaker_id = turn.get("speaker")
            start = float(turn.get("start"))
            end = float(turn.get("end"))
        except (AttributeError, TypeError, ValueError):
            continue
        if (
            not isinstance(speaker_id, str)
            or not speaker_id.strip()
            or not math.isfinite(start)
            or not math.isfinite(end)
            or start < 0
            or end <= start
        ):
            continue
        valid_turns.append((start, speaker_id, start + (end - start) / 2))

    for _, speaker_id, timestamp in sorted(valid_turns):
        if speaker_id not in grouped:
            grouped[speaker_id] = []
            first_seen.append(speaker_id)
        if len(grouped[speaker_id]) < MAX_FRAMES_PER_SPEAKER:
            grouped[speaker_id].append(timestamp)

    # Round-robin gives each diarized speaker evidence before spending the
    # remaining bounded frame budget on second and third observations.
    selected: list[tuple[str, float]] = []
    for round_index in range(MAX_FRAMES_PER_SPEAKER):
        for speaker_id in first_seen:
            timestamps = grouped[speaker_id]
            if round_index < len(timestamps):
                selected.append((speaker_id, timestamps[round_index]))
                if len(selected) == MAX_FRAMES:
                    return selected
    return selected


def _candidate_names(candidate_names: Iterable[str]) -> tuple[str, ...]:
    unique: dict[str, str] = {}
    for raw_name in candidate_names:
        if not isinstance(raw_name, str):
            continue
        name = " ".join(raw_name.split())
        words = re.findall(r"[^\W\d_]+(?:['’][^\W\d_]+)?", name, flags=re.UNICODE)
        if len(words) < 2 or len(name) > 100:
            continue
        unique.setdefault(name.casefold(), name)
    return tuple(unique.values())


def _evidence_from_ocr(
    payload: Any,
    frames: Sequence[tuple[Path, str, float]],
    candidates: tuple[str, ...],
) -> dict[str, list[dict[str, Any]]]:
    if not isinstance(payload, dict) or payload.get("schema_version") != 1:
        return {}
    raw_frames = payload.get("frames")
    if not isinstance(raw_frames, list) or len(raw_frames) > len(frames):
        return {}
    expected = {str(path): (speaker_id, timestamp) for path, speaker_id, timestamp in frames}
    found: dict[str, dict[tuple[str, str], set[float]]] = defaultdict(lambda: defaultdict(set))
    seen_paths: set[str] = set()
    for raw_frame in raw_frames:
        if not isinstance(raw_frame, dict):
            continue
        path = raw_frame.get("path")
        if not isinstance(path, str) or path not in expected or path in seen_paths:
            continue
        seen_paths.add(path)
        observations = raw_frame.get("observations")
        if not isinstance(observations, list) or len(observations) > 10_000:
            continue
        speaker_id, timestamp = expected[path]
        evidence_at_timestamp: set[tuple[str, str]] = set()
        for observation in observations:
            if not _valid_ocr_observation(observation):
                continue
            active_names = _matched_active_speaker_names(observation["text"], candidates)
            if active_names:
                evidence_at_timestamp.update((name, "active_speaker_label") for name in active_names)
                continue
            if _has_participant_label_geometry(observation):
                evidence_at_timestamp.update(
                    (name, "video_label")
                    for name in _matched_candidate_names(observation["text"], candidates)
                )
        # Keeping every visible known name is intentional. Gallery frames are
        # supporting evidence only and cannot identify the active voice.
        for name_and_source in evidence_at_timestamp:
            found[speaker_id][name_and_source].add(round(timestamp, 3))

    return {
        speaker_id: [
            {"name": name, "timestamps": sorted(timestamps), "source": source}
            for (name, source), timestamps in sorted(
                names.items(), key=lambda item: (item[0][0].casefold(), item[0][1]),
            )
        ]
        for speaker_id, names in found.items()
        if names
    }


def _valid_ocr_observation(observation: Any) -> bool:
    if not isinstance(observation, dict) or not isinstance(observation.get("text"), str):
        return False
    try:
        confidence = float(observation.get("confidence"))
        box = observation.get("bounding_box")
        x = float(box["x"])
        y = float(box["y"])
        width = float(box["width"])
        height = float(box["height"])
    except (KeyError, TypeError, ValueError):
        return False
    values = (confidence, x, y, width, height)
    if not all(math.isfinite(value) for value in values):
        return False
    if confidence < MIN_OCR_CONFIDENCE:
        return False
    if x < 0 or y < 0 or width <= 0 or height < 0.008 or x + width > 1.001 or y + height > 1.001:
        return False
    return width <= 0.9 and height <= 0.12


def _has_participant_label_geometry(observation: Mapping[str, Any]) -> bool:
    box = observation["bounding_box"]
    y = float(box["y"])
    width = float(box["width"])
    height = float(box["height"])
    if width > 0.65 or height > 0.08 or y + height >= 0.93:
        return False
    # Zoom's bottom toolbar consumes roughly the lowest tenth of the captured
    # window. Its bottom-row participant labels therefore sit just above it,
    # rather than near normalized y=0.
    if y <= 0.16:
        return True
    lower_edges = {index / rows for rows in range(1, 5) for index in range(rows)}
    return any(0 <= y - edge <= 0.08 for edge in lower_edges)


def _matched_active_speaker_names(text: str, candidates: tuple[str, ...]) -> set[str]:
    normalized = " ".join(text.split())
    matches = set()
    for name in candidates:
        pattern = re.compile(
            rf"^(?:talking|speaking)\s*:\s*{re.escape(name)}\s*[.!?…]*$",
            re.IGNORECASE,
        )
        if pattern.fullmatch(normalized):
            matches.add(name)
    return matches


def _matched_candidate_names(text: str, candidates: tuple[str, ...]) -> set[str]:
    normalized = " ".join(text.split())
    folded = normalized.casefold()
    if len(normalized) > 240 or "zoom meeting" in folded or "zoom webinar" in folded:
        return set()

    matches: list[tuple[int, int, str]] = []
    for name in sorted(candidates, key=len, reverse=True):
        pattern = re.compile(rf"(?<!\w){re.escape(name)}(?!\w)", re.IGNORECASE)
        for match in pattern.finditer(normalized):
            if any(match.start() < end and match.end() > start for start, end, _ in matches):
                continue
            matches.append((match.start(), match.end(), name))
    if not matches:
        return set()

    remainder = list(normalized)
    for start, end, _ in matches:
        remainder[start:end] = " " * (end - start)
    extra_words = {word.casefold() for word in re.findall(r"[^\W\d_]+", "".join(remainder), flags=re.UNICODE)}
    if not extra_words.issubset({"host", "co", "cohost", "me", "you"}):
        return set()
    return {name for _, _, name in matches}


def _is_regular_file(path: Path) -> bool:
    try:
        mode = path.lstat().st_mode
        return stat.S_ISREG(mode)
    except OSError:
        return False


def _is_executable_regular_file(path: Path) -> bool:
    return _is_regular_file(path) and os.access(path, os.X_OK)


def _find_ffmpeg() -> str | None:
    if found := shutil.which("ffmpeg"):
        return found
    for candidate in FFMPEG_FALLBACKS:
        # Homebrew's stable bin entry may be a symlink into its versioned
        # Cellar. Follow it, but require the resolved target to be a file and
        # executable before it can become a subprocess argument.
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def _format_timestamp(timestamp: float) -> str:
    return f"{timestamp:.3f}"
