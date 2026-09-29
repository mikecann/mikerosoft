"""Bounded, case-insensitive transcript search across accepted meetings."""

from __future__ import annotations

import json
import math
import sqlite3
import stat
from datetime import datetime
from pathlib import Path
from typing import Any

from .db import closing_connection
from .titles import effective_title


MIN_QUERY_LENGTH = 2
MAX_QUERY_LENGTH = 200
DEFAULT_LIMIT = 20
MAX_LIMIT = 100
MATCHES_PER_MEETING = 5
MAX_MATCH_TEXT = 1_000
# Same caps the status command uses when it reads archive JSON.
MAX_TRANSCRIPT_BYTES = 16 * 1024 * 1024
MAX_METADATA_BYTES = 1024 * 1024
# Stop scanning once this much transcript JSON has been read in one search.
MAX_SCAN_BYTES = 512 * 1024 * 1024


def normalize_query(value: Any) -> str:
    query = value.strip() if isinstance(value, str) else ""
    if not MIN_QUERY_LENGTH <= len(query) <= MAX_QUERY_LENGTH:
        raise ValueError(
            f"The search query must be {MIN_QUERY_LENGTH} to {MAX_QUERY_LENGTH} characters.",
        )
    return query


def _read_json(path: Path, maximum_bytes: int) -> tuple[Any, int] | None:
    """Parse a regular, bounded JSON file; anything else is skipped, not fatal."""
    try:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_size > maximum_bytes:
            return None
        return json.loads(path.read_text(encoding="utf-8")), info.st_size
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None


def _timestamp(*values: Any) -> float:
    for value in values:
        if isinstance(value, str):
            try:
                return datetime.fromisoformat(value).timestamp()
            except ValueError:
                continue
    return 0.0


def _matches(transcript: dict[str, Any], needle: str) -> list[dict[str, Any]]:
    found = []
    for turn in transcript["turns"]:
        if not isinstance(turn, dict) or not isinstance(turn.get("text"), str):
            continue
        if needle not in turn["text"].casefold():
            continue
        try:
            start = float(turn.get("start", 0))
        except (TypeError, ValueError):
            start = 0.0
        speaker = turn.get("name") or turn.get("speaker")
        found.append({
            "start_seconds": start if math.isfinite(start) else 0.0,
            "speaker": speaker if isinstance(speaker, str) else None,
            "text": turn["text"].strip()[:MAX_MATCH_TEXT],
        })
        if len(found) >= MATCHES_PER_MEETING:
            break
    return found


def search_transcripts(
    database: Path,
    archive_root: Path,
    query: str,
    limit: int = DEFAULT_LIMIT,
) -> dict[str, Any]:
    query = normalize_query(query)
    if not 1 <= limit <= MAX_LIMIT:
        raise ValueError(f"The search limit must be between 1 and {MAX_LIMIT}.")
    with closing_connection(lambda: sqlite3.connect(database, timeout=30)) as connection:
        rows = connection.execute(
            "SELECT meeting_id, manifest_revision, archive_path, accepted_at FROM acceptances",
        ).fetchall()

    meetings = []
    for meeting_id, revision, archive_path, accepted_at in rows:
        archive = Path(archive_path)
        if not archive.is_absolute():
            archive = archive_root / archive
        parsed = _read_json(archive / "metadata.json", MAX_METADATA_BYTES)
        metadata = parsed[0] if parsed and isinstance(parsed[0], dict) else {}
        started = _timestamp(metadata.get("started_at"), accepted_at)
        meetings.append((started, meeting_id, int(revision), archive, metadata))
    meetings.sort(key=lambda item: (item[0], item[1]), reverse=True)

    needle = query.casefold()
    results = []
    scanned = 0
    for _started, meeting_id, revision, archive, metadata in meetings:
        if len(results) >= limit or scanned >= MAX_SCAN_BYTES:
            break
        parsed = _read_json(archive / "transcripts" / f"v{revision}" / "transcript.json", MAX_TRANSCRIPT_BYTES)
        if parsed is None:
            continue
        transcript, size = parsed
        scanned += size
        if (
            not isinstance(transcript, dict)
            or transcript.get("meeting_id") != meeting_id
            or transcript.get("manifest_revision") != revision
            or not isinstance(transcript.get("turns"), list)
        ):
            continue
        matches = _matches(transcript, needle)
        if matches:
            results.append({
                "meeting_id": meeting_id,
                "title": effective_title(archive, metadata),
                "matches": matches,
            })
    return {"schema_version": 1, "results": results}
