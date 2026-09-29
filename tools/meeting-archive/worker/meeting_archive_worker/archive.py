"""Idempotent, hash-verified acceptance into permanent storage."""

from __future__ import annotations

import hashlib
import os
import shutil
import stat
import sys
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from collections.abc import Callable

from .manifest import VerifiedFile, VerifiedManifest, verified_source_path, verify_incoming
from .media_validation import validate_media_files
from .queue import JobQueue, QueueConflict


class ArchiveConflict(RuntimeError):
    """Permanent storage already contains a different manifest or file."""


def _fsync_directory(path: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _write_exclusive(path: Path, data: bytes) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        view = memoryview(data)
        while view:
            written = os.write(descriptor, view)
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


class ArchiveStore:
    def __init__(
        self,
        archive_root: Path | str,
        database_path: Path | str,
        *,
        validate_media: bool = False,
        media_validator: Callable[[Path, VerifiedManifest], dict[str, Any]] = validate_media_files,
        incoming_root: Path | str | None = None,
    ):
        self.archive_root = Path(archive_root).absolute()
        self.queue = JobQueue(database_path)
        self.validate_media = validate_media
        self.media_validator = media_validator
        # Staged bundles under incoming_root/<meeting>/r<revision> are removed
        # once their archive copy is durable. None keeps every staged copy.
        self.incoming_root = Path(os.path.abspath(incoming_root)) if incoming_root is not None else None

    def accept(
        self,
        incoming_directory: Path | str,
        expected_manifest_sha256: str | None = None,
    ) -> dict[str, Any]:
        incoming = Path(incoming_directory)
        if not os.path.lexists(incoming) and expected_manifest_sha256 is not None:
            # A retry after an ambiguous success may find its staging already
            # removed. The committed receipt still answers it.
            acknowledgement = self._accepted_without_staging(incoming, expected_manifest_sha256)
            if acknowledgement is not None:
                return acknowledgement
        verified = verify_incoming(incoming)
        acknowledgement = self._accept_verified(verified, expected_manifest_sha256)
        # Only reached once the archive copy is verified and the job and
        # receipt are committed, so the staged copy is now redundant.
        self._remove_staging(incoming, verified)
        return acknowledgement

    def _staging_identity(self, incoming: Path) -> tuple[str, int] | None:
        if self.incoming_root is None:
            return None
        # Lexical check only: a symlinked component is refused at removal time.
        parts = Path(os.path.abspath(incoming)).parts
        root_parts = self.incoming_root.parts
        if parts[: len(root_parts)] != root_parts:
            return None
        relative = parts[len(root_parts):]
        if len(relative) != 2 or not relative[1].startswith("r") or not relative[1][1:].isdigit():
            return None
        try:
            meeting_id = str(uuid.UUID(relative[0]))
        except ValueError:
            return None
        if meeting_id != relative[0]:
            return None
        return meeting_id, int(relative[1][1:])

    def _accepted_without_staging(self, incoming: Path, expected_manifest_sha256: str) -> dict[str, Any] | None:
        identity = self._staging_identity(incoming)
        if identity is None:
            return None
        meeting_id, revision = identity
        existing_ack = self.queue.acceptance(meeting_id)
        if (
            existing_ack is None
            or existing_ack["manifest_revision"] != revision
            or existing_ack["manifest_sha256"] != expected_manifest_sha256
        ):
            return None
        # The archive copy stands in for the staged bundle it was verified against.
        verified = verify_incoming(self._archive_path(existing_ack))
        return self._existing_acceptance(existing_ack, verified, archive_verified=True)

    def _archive_path(self, acknowledgement: dict[str, Any]) -> Path:
        path = Path(acknowledgement["archive_path"])
        return path if path.is_absolute() else self.archive_root / path

    def _remove_staging(self, incoming: Path, verified: VerifiedManifest) -> None:
        identity = self._staging_identity(incoming)
        if identity != (verified.meeting_id, verified.revision) or self.incoming_root is None:
            return
        meeting_directory = self.incoming_root / verified.meeting_id
        staging = meeting_directory / f"r{verified.revision}"
        try:
            for path in (self.incoming_root, meeting_directory, staging):
                entry_stat = path.lstat()
                if stat.S_ISLNK(entry_stat.st_mode) or not stat.S_ISDIR(entry_stat.st_mode):
                    # Never follow a link out of the incoming root.
                    return
            shutil.rmtree(staging)
            try:
                meeting_directory.rmdir()
            except OSError:
                pass  # Another revision is still staged here.
        except OSError as error:
            # The receipt is already committed; a leftover copy only costs space.
            print(
                f"meeting-archive: accepted, but could not remove staged copy {staging}: {error}",
                file=sys.stderr,
                flush=True,
            )

    def _existing_acceptance(
        self,
        existing_ack: dict[str, Any],
        verified: VerifiedManifest,
        *,
        archive_verified: bool = False,
    ) -> dict[str, Any]:
        if (
            existing_ack["manifest_revision"] != verified.revision
            or existing_ack["manifest_sha256"] != verified.manifest_sha256
        ):
            raise ArchiveConflict(
                f"Meeting {verified.meeting_id} was already accepted with a different manifest.",
            )
        if not archive_verified:
            self._verify_existing(Path(existing_ack["archive_path"]), verified)
        if self.validate_media and existing_ack.get("media_validation", {}).get("status") != "passed":
            media_validation = self.media_validator(Path(existing_ack["archive_path"]), verified)
            self._verify_existing(Path(existing_ack["archive_path"]), verified)
            return self.queue.attach_media_validation(
                verified.meeting_id,
                verified.revision,
                verified.manifest_sha256,
                media_validation,
            )
        return existing_ack

    def _accept_verified(
        self,
        verified: VerifiedManifest,
        expected_manifest_sha256: str | None,
    ) -> dict[str, Any]:
        if expected_manifest_sha256 is not None and verified.manifest_sha256 != expected_manifest_sha256:
            raise ArchiveConflict("The supplied manifest SHA-256 does not match manifest.json bytes.")
        existing_ack = self.queue.acceptance(verified.meeting_id)
        if existing_ack:
            return self._existing_acceptance(existing_ack, verified)

        self._prepare_root()
        relative_archive = Path(
            f"{verified.started_at.year:04d}",
            f"{verified.started_at.month:02d}",
            verified.meeting_id,
        )
        destination = self.archive_root / relative_archive
        other = self._find_existing_meeting(verified.meeting_id)
        if other is not None and other != destination:
            raise ArchiveConflict(
                f"Meeting {verified.meeting_id} already exists at a different archive path.",
            )
        self._materialize(destination, verified)
        media_validation = None
        if self.validate_media:
            media_validation = self.media_validator(destination, verified)
            # Validation opens paths through ffmpeg/ffprobe. Recheck the durable
            # bytes afterwards so a raced replacement can never earn cleanup.
            self._verify_existing(destination, verified)
        archive_path = str(destination)
        try:
            return self.queue.record_acceptance(
                meeting_id=verified.meeting_id,
                manifest_revision=verified.revision,
                manifest_sha256=verified.manifest_sha256,
                archive_path=archive_path,
                accepted_at=datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
                verified_files=[
                    {
                        "path": item.path,
                        "size_bytes": item.size_bytes,
                        "sha256": item.sha256,
                        "kind": item.kind,
                    }
                    for item in verified.files
                ],
                media_validation=media_validation,
            )
        except QueueConflict as error:
            raise ArchiveConflict(str(error)) from error

    def _prepare_root(self) -> None:
        try:
            root_stat = self.archive_root.lstat()
        except FileNotFoundError as error:
            raise ArchiveConflict(
                "The archive root must already exist on the verified permanent volume.",
            ) from error
        if stat.S_ISLNK(root_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
            raise ArchiveConflict("The archive root must be a real directory, not a symbolic link.")

    def _find_existing_meeting(self, meeting_id: str) -> Path | None:
        matches: list[Path] = []
        for year in self.archive_root.iterdir():
            if not year.is_dir() or year.is_symlink():
                continue
            for month in year.iterdir():
                if not month.is_dir() or month.is_symlink():
                    continue
                candidate = month / meeting_id
                if candidate.exists() or candidate.is_symlink():
                    matches.append(candidate)
        if len(matches) > 1:
            raise ArchiveConflict(f"Meeting {meeting_id} exists in multiple archive locations.")
        return matches[0] if matches else None

    def _materialize(self, destination: Path, verified: VerifiedManifest) -> None:
        current = self.archive_root
        for part in destination.relative_to(self.archive_root).parts[:-1]:
            current = current / part
            try:
                current.mkdir(mode=0o700)
            except FileExistsError as error:
                entry_stat = current.lstat()
                if stat.S_ISLNK(entry_stat.st_mode) or not stat.S_ISDIR(entry_stat.st_mode):
                    raise ArchiveConflict(
                        f"Archive path component {part!r} is not a real directory.",
                    ) from error
        try:
            destination.mkdir(mode=0o700)
        except FileExistsError as error:
            if destination.is_symlink() or not destination.is_dir():
                raise ArchiveConflict("The archive destination is not a real directory.") from error

        # Publishing is additive and uses exclusive creates/links. A crash can
        # leave a partial directory, and an identical retry safely fills only
        # missing paths. Existing archive inputs are never overwritten.
        manifest_path = destination / "manifest.json"
        try:
            _write_exclusive(manifest_path, verified.manifest_bytes)
        except FileExistsError:
            if self._secure_archive_bytes(
                manifest_path,
                "manifest.json",
                maximum_bytes=8 * 1024 * 1024,
            ) != verified.manifest_bytes:
                raise ArchiveConflict(
                    f"Existing archive for {verified.meeting_id} has a different manifest.",
                )
        _fsync_directory(destination)
        for item in verified.files:
            self._install_file(destination, verified, item)
        self._verify_existing(destination, verified)
        _fsync_directory(destination)
        _fsync_directory(destination.parent)

    def _install_file(
        self,
        destination: Path,
        verified: VerifiedManifest,
        item: VerifiedFile,
    ) -> None:
        target = destination.joinpath(*item.path.split("/"))
        self._ensure_archive_parent(destination, item.path)
        if target.exists() or target.is_symlink():
            size, digest = self._secure_archive_hash(target, item.path)
            if size != item.size_bytes or digest != item.sha256:
                raise ArchiveConflict(f"Archive target {item.path} conflicts with the manifest.")
            return
        temporary = target.parent / f".{target.name}.{uuid.uuid4().hex}.part"
        try:
            self._copy_source_exclusive(verified, item, temporary)
            try:
                # Hard-link publication is atomic and never replaces an existing archive input.
                os.link(temporary, target, follow_symlinks=False)
            except FileExistsError:
                size, digest = self._secure_archive_hash(target, item.path)
                if size != item.size_bytes or digest != item.sha256:
                    raise ArchiveConflict(f"Archive target {item.path} appeared with different content.")
        finally:
            temporary.unlink(missing_ok=True)
        _fsync_directory(target.parent)

    @staticmethod
    def _ensure_archive_parent(destination: Path, relative_path: str) -> None:
        current = destination
        for part in relative_path.split("/")[:-1]:
            current = current / part
            try:
                current.mkdir(mode=0o700)
            except FileExistsError:
                entry_stat = current.lstat()
                if stat.S_ISLNK(entry_stat.st_mode) or not stat.S_ISDIR(entry_stat.st_mode):
                    raise ArchiveConflict(
                        f"Archive path component {part!r} is not a real directory.",
                    )

    @staticmethod
    def _secure_archive_descriptor(path: Path, label: str) -> int:
        try:
            entry_stat = path.lstat()
        except FileNotFoundError as error:
            raise ArchiveConflict(f"Archive target {label} is missing.") from error
        if stat.S_ISLNK(entry_stat.st_mode) or not stat.S_ISREG(entry_stat.st_mode):
            raise ArchiveConflict(f"Archive target {label} is not a regular file.")
        flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(path, flags)
        except OSError as error:
            raise ArchiveConflict(f"Could not securely read archive target {label}: {error}") from error
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            os.close(descriptor)
            raise ArchiveConflict(f"Archive target {label} is not a regular file.")
        return descriptor

    @classmethod
    def _secure_archive_bytes(cls, path: Path, label: str, maximum_bytes: int) -> bytes:
        descriptor = cls._secure_archive_descriptor(path, label)
        try:
            if os.fstat(descriptor).st_size > maximum_bytes:
                raise ArchiveConflict(f"Archive target {label} exceeds its safety limit.")
            chunks: list[bytes] = []
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                chunks.append(chunk)
            return b"".join(chunks)
        finally:
            os.close(descriptor)

    @classmethod
    def _secure_archive_hash(cls, path: Path, label: str) -> tuple[int, str]:
        descriptor = cls._secure_archive_descriptor(path, label)
        try:
            size = 0
            digest = hashlib.sha256()
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                size += len(chunk)
                digest.update(chunk)
            return size, digest.hexdigest()
        finally:
            os.close(descriptor)

    @staticmethod
    def _copy_source_exclusive(
        verified: VerifiedManifest,
        item: VerifiedFile,
        target: Path,
    ) -> None:
        source = verified_source_path(verified, item)
        source_flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
        destination_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0)
        source_descriptor = os.open(source, source_flags)
        try:
            opened_source_stat = os.fstat(source_descriptor)
            if not stat.S_ISREG(opened_source_stat.st_mode):
                raise ArchiveConflict(f"Source {item.path} is not a regular file.")
            destination_descriptor = os.open(target, destination_flags, 0o600)
            try:
                size = 0
                digest = hashlib.sha256()
                while True:
                    chunk = os.read(source_descriptor, 1024 * 1024)
                    if not chunk:
                        break
                    size += len(chunk)
                    digest.update(chunk)
                    view = memoryview(chunk)
                    while view:
                        written = os.write(destination_descriptor, view)
                        if written <= 0:
                            raise OSError("Archive write made no progress.")
                        view = view[written:]
                if size != item.size_bytes or digest.hexdigest() != item.sha256:
                    raise ArchiveConflict(f"{item.path} changed after manifest verification.")
                final_source_stat = os.fstat(source_descriptor)
                if (
                    opened_source_stat.st_dev,
                    opened_source_stat.st_ino,
                    opened_source_stat.st_size,
                    opened_source_stat.st_mtime_ns,
                ) != (
                    final_source_stat.st_dev,
                    final_source_stat.st_ino,
                    final_source_stat.st_size,
                    final_source_stat.st_mtime_ns,
                ):
                    raise ArchiveConflict(f"{item.path} changed while it was copied.")
                os.fsync(destination_descriptor)
            finally:
                os.close(destination_descriptor)
        finally:
            os.close(source_descriptor)

    def _verify_existing(self, destination: Path, expected: VerifiedManifest) -> None:
        if not destination.is_absolute():
            destination = self.archive_root / destination
        try:
            archived = verify_incoming(destination)
        except Exception as error:
            raise ArchiveConflict(f"Existing archive for {expected.meeting_id} is incomplete or unsafe: {error}") from error
        if (
            archived.meeting_id != expected.meeting_id
            or archived.revision != expected.revision
            or archived.manifest_sha256 != expected.manifest_sha256
        ):
            raise ArchiveConflict(
                f"Existing archive for {expected.meeting_id} has a different manifest.",
            )
