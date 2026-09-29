"""User renames stored beside the immutable, manifest-hashed metadata.json."""

from __future__ import annotations

import json
import os
import stat
import unicodedata
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .durable_files import atomic_write_text


TITLE_NAME = "title.json"
MAX_TITLE_LENGTH = 200
MAX_TITLE_FILE_BYTES = 64 * 1024


def normalize_title(value: Any) -> str:
    """Trim a user title and reject empty, oversized or control-character text."""
    if not isinstance(value, str):
        raise ValueError("The meeting title must be text.")
    title = value.strip()
    if not title:
        raise ValueError("The meeting title must not be empty.")
    if len(title) > MAX_TITLE_LENGTH:
        raise ValueError(f"The meeting title must be at most {MAX_TITLE_LENGTH} characters.")
    # Cc covers tabs and newlines; Zl/Zp are Unicode line and paragraph breaks.
    if any(unicodedata.category(character) in ("Cc", "Zl", "Zp") for character in title):
        raise ValueError("The meeting title must not contain control characters or line breaks.")
    return title


def title_override(record: Any) -> str | None:
    """The title from a parsed title.json, or None when it is not usable."""
    if not isinstance(record, dict) or record.get("schema_version") != 1:
        return None
    try:
        return normalize_title(record.get("title"))
    except ValueError:
        return None


def read_title_override(archive_dir: Path | str) -> str | None:
    path = Path(archive_dir) / TITLE_NAME
    try:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_TITLE_FILE_BYTES:
            return None
        return title_override(json.loads(path.read_text(encoding="utf-8")))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        # A damaged rename must never hide the meeting; fall back to metadata.
        return None


def effective_title(archive_dir: Path | str, metadata: dict[str, Any]) -> str | None:
    """Prefer the user's rename, then the captured title. Callers pick the fallback."""
    override = read_title_override(archive_dir)
    if override is not None:
        return override
    captured = metadata.get("title") if isinstance(metadata, dict) else None
    return captured if isinstance(captured, str) and captured.strip() else None


def write_title(archive_dir: Path | str, title: str) -> str:
    """Atomically record a rename. Rewriting the same title leaves the file untouched."""
    archive = Path(archive_dir)
    title = normalize_title(title)
    manifest = json.loads((archive / "manifest.json").read_text(encoding="utf-8"))
    declared = {
        str(entry.get("path", "")).casefold()
        for entry in manifest.get("files", [])
        if isinstance(entry, dict)
    }
    if TITLE_NAME in declared:
        # Never overwrite a preserved, manifest-hashed source file.
        raise ValueError(f"This archive declares {TITLE_NAME} as a source file; it cannot be renamed.")
    if read_title_override(archive) == title:
        return title
    path = archive / TITLE_NAME
    if os.path.lexists(path) and not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError(f"{TITLE_NAME} must be a regular file.")
    updated_at = datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    record = {"schema_version": 1, "title": title, "updated_at": updated_at}
    atomic_write_text(path, json.dumps(record, ensure_ascii=False, sort_keys=True, indent=2) + "\n")
    return title
