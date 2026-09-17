"""Durably reconcile speaker confirmations into derived archive artifacts."""

from __future__ import annotations

import json
import math
import os
import sqlite3
import stat
import time
from contextlib import contextmanager
from pathlib import Path

from .db import closing_connection


LOCK_NAME = ".speaker-refresh.lock"
MAX_TRANSCRIPT_BYTES = 16 * 1024 * 1024


@contextmanager
def speaker_archive_lock(
    archive: Path | str,
    revision: int,
    *,
    timeout_seconds: float = 30.0,
):
    """Serialize transcript mutations through an owner-only derived lock file."""

    if not isinstance(revision, int) or isinstance(revision, bool) or revision < 1:
        raise ValueError("A speaker archive lock needs a positive revision.")
    if (
        not isinstance(timeout_seconds, (int, float))
        or isinstance(timeout_seconds, bool)
        or not math.isfinite(timeout_seconds)
        or timeout_seconds < 0
    ):
        raise ValueError("Speaker archive lock timeout must be finite and nonnegative.")
    directory = Path(archive) / "transcripts" / f"v{revision}"
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise ValueError("Speaker transcript directory must be a real directory.")
    path = directory / LOCK_NAME
    descriptor = os.open(
        path,
        os.O_RDWR
        | os.O_CREAT
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0),
        0o600,
    )
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode):
            raise ValueError("Speaker archive lock must be a regular file.")
        if hasattr(os, "geteuid") and opened.st_uid != os.geteuid():
            raise ValueError("Speaker archive lock must be owned by the worker user.")
        if hasattr(os, "fchmod"):
            os.fchmod(descriptor, 0o600)
        deadline = time.monotonic() + float(timeout_seconds)
        acquired = False
        if os.name == "nt":
            import msvcrt

            if opened.st_size == 0:
                os.write(descriptor, b"0")
            while not acquired:
                os.lseek(descriptor, 0, os.SEEK_SET)
                try:
                    msvcrt.locking(descriptor, msvcrt.LK_NBLCK, 1)
                    acquired = True
                except OSError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError("Timed out waiting for the speaker archive lock.")
                    time.sleep(min(0.05, max(0.0, deadline - time.monotonic())))
        else:
            import fcntl

            while not acquired:
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    acquired = True
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError("Timed out waiting for the speaker archive lock.")
                    time.sleep(min(0.05, max(0.0, deadline - time.monotonic())))
        try:
            yield path
        finally:
            if os.name == "nt":
                import msvcrt

                os.lseek(descriptor, 0, os.SEEK_SET)
                msvcrt.locking(descriptor, msvcrt.LK_UNLCK, 1)
            else:
                import fcntl

                fcntl.flock(descriptor, fcntl.LOCK_UN)
    finally:
        os.close(descriptor)


def _pending_generation(
    database: Path,
    meeting_id: str,
    revision: int,
) -> int | None:
    with closing_connection(lambda: sqlite3.connect(database)) as connection:
        row = connection.execute(
            "SELECT generation FROM speaker_refreshes WHERE meeting_id=? "
            "AND manifest_revision=?",
            (meeting_id, revision),
        ).fetchone()
    return int(row[0]) if row else None


def _accepted_archive(
    database: Path,
    meeting_id: str,
    revision: int,
) -> tuple[Path, int] | None:
    with closing_connection(lambda: sqlite3.connect(database)) as connection:
        row = connection.execute(
            "SELECT acknowledgement_json FROM acceptances WHERE meeting_id=? "
            "AND manifest_revision=?",
            (meeting_id, revision),
        ).fetchone()
    if row is None:
        return None
    acknowledgement = json.loads(row[0])
    if (
        not isinstance(acknowledgement, dict)
        or acknowledgement.get("meeting_id") != meeting_id
        or acknowledgement.get("manifest_revision") != revision
        or not isinstance(acknowledgement.get("archive_path"), str)
    ):
        raise ValueError("Speaker refresh acceptance identity does not match.")
    queue_job_id = acknowledgement.get("queue_job_id")
    if isinstance(queue_job_id, str) and queue_job_id.isdigit():
        queue_job_id = int(queue_job_id)
    if not isinstance(queue_job_id, int) or isinstance(queue_job_id, bool):
        raise ValueError("Speaker refresh acceptance has no queue job id.")
    return Path(acknowledgement["archive_path"]), queue_job_id


def _record_error(
    database: Path,
    meeting_id: str,
    revision: int,
    generation: int,
    error: BaseException,
) -> None:
    message = f"{type(error).__name__}: {error}"[:1000]
    with closing_connection(lambda: sqlite3.connect(database)) as connection:
        connection.execute(
            "UPDATE speaker_refreshes SET attempts=attempts+1, last_error=? "
            "WHERE meeting_id=? AND manifest_revision=? AND generation=?",
            (message, meeting_id, revision, generation),
        )


def reconcile_speaker_refresh(
    database: Path | str,
    meeting_id: str,
    revision: int,
) -> bool:
    """Apply one pending generation; leave it durable when inputs are not ready."""

    database = Path(database)
    generation = _pending_generation(database, meeting_id, revision)
    if generation is None:
        return True
    try:
        accepted = _accepted_archive(database, meeting_id, revision)
        if accepted is None:
            return False
        archive, processing_job_id = accepted
        transcript_path = archive / "transcripts" / f"v{revision}" / "transcript.json"
        try:
            transcript_info = transcript_path.lstat()
        except FileNotFoundError:
            return False
        if (
            not stat.S_ISREG(transcript_info.st_mode)
            or stat.S_ISLNK(transcript_info.st_mode)
            or transcript_info.st_size > MAX_TRANSCRIPT_BYTES
        ):
            raise ValueError("Speaker refresh transcript is missing or unsafe.")

        with speaker_archive_lock(archive, revision):
            # A caller may have refreshed while this process waited for the file
            # lock. Work from the newest durable generation and current JSON.
            generation = _pending_generation(database, meeting_id, revision)
            if generation is None:
                return True
            transcript = json.loads(transcript_path.read_text(encoding="utf-8"))
            if (
                not isinstance(transcript, dict)
                or transcript.get("meeting_id") != meeting_id
                or transcript.get("manifest_revision") != revision
                or not isinstance(transcript.get("turns"), list)
            ):
                raise ValueError("Speaker refresh transcript identity does not match.")

            # Lazy imports avoid service -> speaker_refresh -> service and
            # model_processor -> service import cycles.
            from .model_processor import _write_transcript_artifacts
            from .speaker_evidence import refresh_speaker_matches
            from .speakers import SpeakerRegistry
            from .service import PublicationQueue

            registry = SpeakerRegistry(database)
            refresh_speaker_matches(transcript, registry)
            _write_transcript_artifacts(transcript_path.parent, transcript)
            PublicationQueue(database).refresh(processing_job_id, str(archive))
            with closing_connection(lambda: sqlite3.connect(database)) as connection:
                connection.execute(
                    "DELETE FROM speaker_refreshes WHERE meeting_id=? "
                    "AND manifest_revision=? AND generation=?",
                    (meeting_id, revision, generation),
                )
        return True
    except Exception as error:
        _record_error(database, meeting_id, revision, generation, error)
        return False


def reconcile_pending_speakers(database: Path | str) -> dict[str, int]:
    """Attempt every pending meeting independently so one failure cannot block work."""

    database = Path(database)
    from .speakers import SpeakerRegistry

    SpeakerRegistry(database)
    with closing_connection(lambda: sqlite3.connect(database)) as connection:
        pending = connection.execute(
            "SELECT meeting_id, manifest_revision FROM speaker_refreshes "
            "ORDER BY requested_at, meeting_id, manifest_revision",
        ).fetchall()
    processed = 0
    for meeting_id, revision in pending:
        if reconcile_speaker_refresh(database, meeting_id, int(revision)):
            processed += 1
    with closing_connection(lambda: sqlite3.connect(database)) as connection:
        remaining, errors = connection.execute(
            "SELECT COUNT(*), COALESCE(SUM(last_error IS NOT NULL), 0) "
            "FROM speaker_refreshes",
        ).fetchone()
    return {
        "processed": processed,
        "remaining": int(remaining),
        "errors": int(errors),
    }


__all__ = [
    "reconcile_pending_speakers",
    "reconcile_speaker_refresh",
    "speaker_archive_lock",
]
