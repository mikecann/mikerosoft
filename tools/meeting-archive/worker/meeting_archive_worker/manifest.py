"""Strict validation for finalized Meeting Archive bundles."""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import stat
import uuid
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Any


class ManifestError(ValueError):
    """The incoming bundle is malformed, incomplete, or unsafe."""


@dataclass(frozen=True)
class VerifiedFile:
    path: str
    size_bytes: int
    sha256: str
    kind: str


@dataclass(frozen=True)
class VerifiedManifest:
    incoming_directory: Path
    meeting_id: str
    revision: int
    manifest_sha256: str
    manifest_bytes: bytes
    files: tuple[VerifiedFile, ...]
    metadata: dict[str, Any]
    started_at: datetime


def verified_source_path(manifest: VerifiedManifest, item: VerifiedFile) -> Path:
    """Resolve a listed source only after checking every in-bundle path component."""
    relative = _portable_relative_path(item.path, item.path)
    return _path_without_symlinks(manifest.incoming_directory, relative, item.path)


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ManifestError(f"JSON contains duplicate key {key!r}.")
        result[key] = value
    return result


def _read_json(data: bytes, label: str) -> dict[str, Any]:
    def reject_constant(value: str) -> None:
        raise ManifestError(f"{label} contains nonstandard number {value}.")

    try:
        value = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=_unique_object,
            parse_constant=reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ManifestError(f"{label} is not valid UTF-8 JSON: {error}") from error
    if not isinstance(value, dict):
        raise ManifestError(f"{label} must contain a JSON object.")
    return value


def _open_regular_file(path: Path, label: str) -> int:
    try:
        file_stat = path.lstat()
    except FileNotFoundError as error:
        raise ManifestError(f"{label} is missing.") from error
    if stat.S_ISLNK(file_stat.st_mode):
        raise ManifestError(f"{label} must not be a symbolic link.")
    if not stat.S_ISREG(file_stat.st_mode):
        raise ManifestError(f"{label} must be a regular file.")

    flags = os.O_RDONLY
    flags |= getattr(os, "O_BINARY", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ManifestError(f"Could not securely open {label}: {error}") from error
    opened_stat = os.fstat(descriptor)
    if not stat.S_ISREG(opened_stat.st_mode):
        os.close(descriptor)
        raise ManifestError(f"{label} must be a regular file.")
    return descriptor


def _regular_file_bytes(path: Path, label: str, maximum_bytes: int) -> bytes:
    descriptor = _open_regular_file(path, label)
    try:
        opened_stat = os.fstat(descriptor)
        if opened_stat.st_size > maximum_bytes:
            raise ManifestError(f"{label} exceeds the {maximum_bytes}-byte safety limit.")
        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        final_stat = os.fstat(descriptor)
        if (
            opened_stat.st_dev,
            opened_stat.st_ino,
            opened_stat.st_size,
            opened_stat.st_mtime_ns,
        ) != (
            final_stat.st_dev,
            final_stat.st_ino,
            final_stat.st_size,
            final_stat.st_mtime_ns,
        ):
            raise ManifestError(f"{label} changed while it was being read.")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _regular_file_hash(path: Path, label: str) -> tuple[int, str]:
    descriptor = _open_regular_file(path, label)
    try:
        opened_stat = os.fstat(descriptor)
        digest = hashlib.sha256()
        size = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            size += len(chunk)
            digest.update(chunk)
        final_stat = os.fstat(descriptor)
        if (
            opened_stat.st_dev,
            opened_stat.st_ino,
            opened_stat.st_size,
            opened_stat.st_mtime_ns,
        ) != (
            final_stat.st_dev,
            final_stat.st_ino,
            final_stat.st_size,
            final_stat.st_mtime_ns,
        ):
            raise ManifestError(f"{label} changed while it was being hashed.")
        return size, digest.hexdigest()
    finally:
        os.close(descriptor)


def _portable_relative_path(value: Any, label: str) -> PurePosixPath:
    if not isinstance(value, str) or not value or "\x00" in value or "\\" in value:
        raise ManifestError(f"{label} must be a portable relative path.")
    path = PurePosixPath(value)
    if path.is_absolute() or str(path) != value:
        raise ManifestError(f"{label} must be a normalized relative path.")
    if any(part in ("", ".", "..") or ":" in part for part in path.parts):
        raise ManifestError(f"{label} must be a portable relative path without traversal.")
    return path


def _path_without_symlinks(root: Path, relative: PurePosixPath, label: str) -> Path:
    current = root
    for index, part in enumerate(relative.parts):
        current = current / part
        try:
            entry_stat = current.lstat()
        except FileNotFoundError as error:
            raise ManifestError(f"{label} is missing.") from error
        if stat.S_ISLNK(entry_stat.st_mode):
            raise ManifestError(f"{label} contains a symbolic link.")
        if index < len(relative.parts) - 1 and not stat.S_ISDIR(entry_stat.st_mode):
            raise ManifestError(f"A parent of {label} is not a directory.")
    return current


def _integer(value: Any, label: str, minimum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ManifestError(f"{label} must be an integer greater than or equal to {minimum}.")
    return value


def _meeting_id(value: Any, label: str) -> str:
    if not isinstance(value, str):
        raise ManifestError(f"{label} must be a canonical UUID string.")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as error:
        raise ManifestError(f"{label} must be a canonical UUID string.") from error
    if str(parsed) != value:
        raise ManifestError(f"{label} must be a canonical lowercase UUID string.")
    return value


def _timestamp(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or re.fullmatch(
        r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})",
        value,
    ) is None:
        raise ManifestError(f"metadata.json {label} must be an RFC3339 timestamp.")
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as error:
        raise ManifestError(f"metadata.json {label} must be an RFC3339 timestamp.") from error
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ManifestError(f"metadata.json {label} must include a UTC offset.")
    return parsed


def _validate_metadata(
    metadata: dict[str, Any],
    meeting_id: str,
    revision: int,
) -> datetime:
    if metadata.get("schema_version") != 1:
        raise ManifestError("metadata.json schema_version must be 1.")
    if _meeting_id(metadata.get("meeting_id"), "metadata.json meeting_id") != meeting_id:
        raise ManifestError("metadata.json meeting_id does not match manifest.json.")
    if _integer(metadata.get("manifest_revision"), "metadata.json manifest_revision", 1) != revision:
        raise ManifestError("metadata.json manifest_revision does not match manifest.json.")
    started_at = _timestamp(metadata.get("started_at"), "started_at")
    ended_at = _timestamp(metadata.get("ended_at"), "ended_at")
    if ended_at < started_at:
        raise ManifestError("metadata.json ended_at must not precede started_at.")
    duration = metadata.get("duration_seconds")
    if (
        isinstance(duration, bool)
        or not isinstance(duration, (int, float))
        or not math.isfinite(duration)
        or duration < 0
    ):
        raise ManifestError("metadata.json duration_seconds must be a nonnegative number.")
    for field in ("timezone", "source_app"):
        if not isinstance(metadata.get(field), str) or not metadata[field].strip():
            raise ManifestError(f"metadata.json {field} must be a nonempty string.")
    return started_at


def verify_incoming(incoming_directory: Path | str) -> VerifiedManifest:
    """Verify one complete incoming directory without mutating it."""

    incoming = Path(incoming_directory).absolute()
    try:
        root_stat = incoming.lstat()
    except FileNotFoundError as error:
        raise ManifestError("The incoming meeting directory does not exist.") from error
    if stat.S_ISLNK(root_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
        raise ManifestError("The incoming meeting path must be a real directory, not a symbolic link.")

    manifest_path = _path_without_symlinks(incoming, PurePosixPath("manifest.json"), "manifest.json")
    manifest_bytes = _regular_file_bytes(manifest_path, "manifest.json", 8 * 1024 * 1024)
    manifest = _read_json(manifest_bytes, "manifest.json")
    allowed_manifest_fields = {"schema_version", "meeting_id", "revision", "files"}
    unknown = set(manifest) - allowed_manifest_fields
    if unknown:
        raise ManifestError(f"manifest.json contains unsupported fields: {', '.join(sorted(unknown))}.")
    if manifest.get("schema_version") != 1:
        raise ManifestError("manifest.json schema_version must be 1.")
    meeting_id = _meeting_id(manifest.get("meeting_id"), "manifest.json meeting_id")
    revision = _integer(manifest.get("revision"), "manifest.json revision", 1)
    raw_files = manifest.get("files")
    if not isinstance(raw_files, list) or not raw_files:
        raise ManifestError("manifest.json files must be a nonempty array.")

    verified: list[VerifiedFile] = []
    seen: set[str] = set()
    for index, entry in enumerate(raw_files):
        label = f"manifest.json files[{index}]"
        if not isinstance(entry, dict):
            raise ManifestError(f"{label} must be an object.")
        if set(entry) != {"path", "size_bytes", "sha256", "kind"}:
            raise ManifestError(f"{label} must contain only path, size_bytes, sha256, and kind.")
        relative = _portable_relative_path(entry.get("path"), f"{label}.path")
        relative_string = str(relative)
        if relative_string == "manifest.json":
            raise ManifestError("manifest.json is implicit and must not list itself in files.")
        if relative_string in seen:
            raise ManifestError(f"manifest.json lists {relative_string!r} more than once.")
        seen.add(relative_string)
        size = _integer(entry.get("size_bytes"), f"{label}.size_bytes", 0)
        digest = entry.get("sha256")
        if (
            not isinstance(digest, str)
            or len(digest) != 64
            or digest != digest.lower()
            or any(character not in "0123456789abcdef" for character in digest)
        ):
            raise ManifestError(f"{label}.sha256 must be a lowercase SHA-256 hex digest.")
        kind = entry.get("kind")
        if not isinstance(kind, str) or not kind.strip():
            raise ManifestError(f"{label}.kind must be a nonempty string.")
        source = _path_without_symlinks(incoming, relative, relative_string)
        actual_size, actual_digest = _regular_file_hash(source, relative_string)
        if actual_size != size:
            raise ManifestError(
                f"Size mismatch for {relative_string}: expected {size}, found {actual_size}.",
            )
        if actual_digest != digest:
            raise ManifestError(
                f"SHA-256 mismatch for {relative_string}: expected {digest}, found {actual_digest}.",
            )
        verified.append(VerifiedFile(relative_string, size, digest, kind))

    if "metadata.json" not in seen:
        raise ManifestError("manifest.json must list metadata.json as a finalized file.")
    metadata_entry = next(item for item in verified if item.path == "metadata.json")
    if metadata_entry.kind != "metadata":
        raise ManifestError("metadata.json must have kind 'metadata'.")
    metadata_path = _path_without_symlinks(
        incoming,
        PurePosixPath("metadata.json"),
        "metadata.json",
    )
    metadata_bytes = _regular_file_bytes(metadata_path, "metadata.json", 8 * 1024 * 1024)
    # The second read is bounded and must still match the finalized bytes.
    if (
        len(metadata_bytes) != metadata_entry.size_bytes
        or hashlib.sha256(metadata_bytes).hexdigest() != metadata_entry.sha256
    ):
        raise ManifestError("metadata.json changed after manifest verification.")
    metadata = _read_json(metadata_bytes, "metadata.json")
    started_at = _validate_metadata(metadata, meeting_id, revision)
    return VerifiedManifest(
        incoming_directory=incoming,
        meeting_id=meeting_id,
        revision=revision,
        manifest_sha256=hashlib.sha256(manifest_bytes).hexdigest(),
        manifest_bytes=manifest_bytes,
        files=tuple(verified),
        metadata=metadata,
        started_at=started_at,
    )
