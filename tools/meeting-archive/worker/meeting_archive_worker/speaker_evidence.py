"""Keep review suggestions, automatic names, and explicit confirmations separate."""

from __future__ import annotations

import hashlib
import json
import math
import sqlite3
import sys
from pathlib import Path

from .db import closing_connection
from .durable_files import atomic_write_bytes
from .visual_labels import default_helper_path, extract_visual_labels
from .speakers import MATCH_MARGIN, STRONG_MATCH_THRESHOLD


def refresh_speaker_matches(transcript: dict, registry) -> None:
    """Refresh derived names without ever enrolling an automatic prediction."""
    meeting_id = transcript["meeting_id"]
    revision = transcript["manifest_revision"]
    assignments = registry.assignments(meeting_id, revision)
    matches = {}
    for speaker in sorted({turn["speaker"] for turn in transcript["turns"] if turn.get("speaker")}):
        observation = registry.observation_record(meeting_id, revision, speaker)
        if observation:
            embedding, model = observation
            # Exclude this recording, including other revisions of it. Otherwise
            # a prior confirmation creates a misleading perfect self-match.
            matches[speaker] = registry.review_match(
                embedding, model_id=model, exclude_meeting_id=meeting_id,
            )
    transcript["speaker_matches"] = matches
    for turn in transcript["turns"]:
        speaker = turn.get("speaker")
        if not speaker:
            continue
        confirmed = assignments.get(speaker)
        automatic = matches.get(speaker, {}).get("automatic_name")
        if confirmed:
            turn.update(name=confirmed, name_source="confirmed")
        elif automatic:
            turn.update(name=automatic, name_source="voice_match")
        else:
            turn.pop("name", None)
            turn.pop("name_source", None)


def automatic_names(transcript: dict) -> dict[str, str]:
    """Only acknowledge strong matches already written to every affected turn."""
    result = {}
    for speaker, match in transcript.get("speaker_matches", {}).items():
        if not isinstance(match, dict):
            continue
        name = match.get("automatic_name")
        score = match.get("suggestion_score")
        margin = match.get("suggestion_margin")
        count = match.get("confirmation_count", 0)
        if (
            not isinstance(name, str) or not name.strip()
            or match.get("suggestion_kind") != "strong"
            or not isinstance(score, (int, float)) or not math.isfinite(score) or score < STRONG_MATCH_THRESHOLD
            or not isinstance(count, int) or count < 1
            or (margin is not None and (
                not isinstance(margin, (int, float)) or not math.isfinite(margin) or margin < MATCH_MARGIN
            ))
        ):
            continue
        turns = [turn for turn in transcript["turns"] if turn.get("speaker") == speaker]
        if turns and all(turn.get("name") == name and turn.get("name_source") == "voice_match" for turn in turns):
            result[speaker] = name
    return result


def known_names(registry) -> list[str]:
    uri = Path(registry.database).resolve().as_uri() + "?mode=ro"
    with closing_connection(lambda: sqlite3.connect(uri, uri=True)) as connection:
        return [row[0] for row in connection.execute(
            "SELECT DISTINCT display_name FROM speaker_assignments ORDER BY display_name",
        )]


def video_label_evidence(archive: Path, transcript: dict, registry) -> dict:
    """Cache optional local OCR evidence; missing OCR never blocks transcription."""
    try:
        video = archive / "playback" / "meeting.mp4"
        helper = default_helper_path()
        if not video.is_file() or not helper.is_file():
            return {}
        names = set(known_names(registry))
        metadata_path = archive / "metadata.json"
        if metadata_path.is_file():
            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
            for candidate in metadata.get("attendees", []):
                name = candidate if isinstance(candidate, str) else candidate.get("name") if isinstance(candidate, dict) else None
                if isinstance(name, str) and name.strip():
                    names.add(name.strip())
        candidates = sorted(names)
        if not candidates:
            return {}
        stat = video.stat()
        key = {
            "recipe": 1,
            "meeting_id": transcript["meeting_id"],
            "revision": transcript["manifest_revision"],
            "manifest_sha256": transcript.get("processing", {}).get("manifest_sha256"),
            "video_size": stat.st_size, "video_mtime_ns": stat.st_mtime_ns,
            "helper_mtime_ns": helper.stat().st_mtime_ns,
            "candidates": candidates,
            "turns": [{key: turn.get(key) for key in ("speaker", "start", "end")} for turn in transcript["turns"]],
        }
        digest = hashlib.sha256(json.dumps(key, sort_keys=True).encode()).hexdigest()
        cache = archive / "transcripts" / f"v{transcript['manifest_revision']}" / "visual-labels.json"
        if cache.is_file() and not cache.is_symlink():
            try:
                saved = json.loads(cache.read_text(encoding="utf-8"))
                if saved.get("key") == digest and isinstance(saved.get("labels"), dict):
                    return saved["labels"]
            except (OSError, ValueError):
                pass
        labels = extract_visual_labels(video, transcript["turns"], candidates, helper_path=helper)
        # Empty results may be a temporary decoder/OCR failure. Retry on a later
        # review instead of making that absence permanent.
        if labels and cache.parent.is_dir() and not cache.parent.is_symlink() and not cache.is_symlink():
            atomic_write_bytes(cache, (json.dumps({"key": digest, "labels": labels}, sort_keys=True) + "\n").encode())
        return labels
    except Exception as error:
        # Names, OCR text and media paths stay out of logs.
        print(f"Optional video label analysis unavailable ({type(error).__name__}).", file=sys.stderr)
        return {}
