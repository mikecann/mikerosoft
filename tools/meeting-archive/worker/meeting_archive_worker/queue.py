"""SQLite-backed durable queue with a single recoverable heavy-job lease."""

from __future__ import annotations

import json
import sqlite3
import stat
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from .db import closing_connection


class QueueConflict(RuntimeError):
    pass


@dataclass(frozen=True)
class Job:
    id: int
    meeting_id: str
    manifest_revision: int
    manifest_sha256: str
    archive_path: str
    state: str
    attempts: int
    lease_owner: str
    lease_expires_at: float


class JobQueue:
    def __init__(self, database_path: Path | str, clock: Callable[[], float] = time.time):
        self.database_path = Path(database_path)
        self.clock = clock
        try:
            parent_stat = self.database_path.parent.lstat()
        except FileNotFoundError as error:
            raise ValueError("The worker database directory must already exist.") from error
        if stat.S_ISLNK(parent_stat.st_mode) or not stat.S_ISDIR(parent_stat.st_mode):
            raise ValueError("The worker database directory must be a real directory.")
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database_path, timeout=30, isolation_level=None)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA journal_mode = WAL")
        connection.execute("PRAGMA synchronous = FULL")
        return connection

    def _initialize(self) -> None:
        with closing_connection(self._connect) as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS acceptances (
                    meeting_id TEXT PRIMARY KEY,
                    manifest_revision INTEGER NOT NULL,
                    manifest_sha256 TEXT NOT NULL,
                    archive_path TEXT NOT NULL,
                    acknowledgement_json TEXT NOT NULL,
                    accepted_at TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS jobs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    meeting_id TEXT NOT NULL,
                    manifest_revision INTEGER NOT NULL,
                    manifest_sha256 TEXT NOT NULL,
                    archive_path TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (
                        state IN ('ready', 'leased', 'retry_wait', 'succeeded', 'permanent_failure')
                    ),
                    attempts INTEGER NOT NULL DEFAULT 0,
                    available_at REAL NOT NULL,
                    lease_owner TEXT,
                    lease_expires_at REAL,
                    last_error TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    UNIQUE (meeting_id, manifest_revision, manifest_sha256)
                );
                """,
            )

    def acceptance(self, meeting_id: str) -> dict[str, Any] | None:
        with closing_connection(self._connect) as connection:
            row = connection.execute(
                "SELECT acknowledgement_json FROM acceptances WHERE meeting_id = ?",
                (meeting_id,),
            ).fetchone()
        return json.loads(row[0]) if row else None

    def record_acceptance(
        self,
        *,
        meeting_id: str,
        manifest_revision: int,
        manifest_sha256: str,
        archive_path: str,
        accepted_at: str,
        verified_files: list[dict[str, Any]],
        media_validation: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Commit the queue job and its cleanup-safe acknowledgement together."""

        now = self.clock()
        with closing_connection(self._connect) as connection:
            connection.execute("BEGIN IMMEDIATE")
            existing = connection.execute(
                "SELECT manifest_revision, manifest_sha256, acknowledgement_json "
                "FROM acceptances WHERE meeting_id = ?",
                (meeting_id,),
            ).fetchone()
            if existing:
                if existing[0] != manifest_revision or existing[1] != manifest_sha256:
                    connection.rollback()
                    raise QueueConflict(
                        f"Meeting {meeting_id} was already accepted with a different manifest.",
                    )
                acknowledgement = json.loads(existing[2])
                connection.commit()
                return acknowledgement

            connection.execute(
                """
                INSERT OR IGNORE INTO jobs (
                    meeting_id, manifest_revision, manifest_sha256, archive_path,
                    state, attempts, available_at, created_at, updated_at
                ) VALUES (?, ?, ?, ?, 'ready', 0, ?, ?, ?)
                """,
                (
                    meeting_id,
                    manifest_revision,
                    manifest_sha256,
                    archive_path,
                    now,
                    now,
                    now,
                ),
            )
            job = connection.execute(
                "SELECT id FROM jobs WHERE meeting_id = ? AND manifest_revision = ? "
                "AND manifest_sha256 = ?",
                (meeting_id, manifest_revision, manifest_sha256),
            ).fetchone()
            if job is None:
                connection.rollback()
                raise RuntimeError("The processing job could not be committed.")
            acknowledgement: dict[str, Any] = {
                "schema_version": 1,
                "meeting_id": meeting_id,
                "manifest_revision": manifest_revision,
                "manifest_sha256": manifest_sha256,
                "archive_path": archive_path,
                "accepted_at": accepted_at,
                "verified_files": verified_files,
                "queue_job_id": str(job[0]),
                "cleanup_allowed": True,
            }
            if media_validation is not None:
                acknowledgement["media_validation"] = media_validation
            acknowledgement_json = json.dumps(
                acknowledgement,
                sort_keys=True,
                separators=(",", ":"),
            )
            connection.execute(
                """
                INSERT INTO acceptances (
                    meeting_id, manifest_revision, manifest_sha256, archive_path,
                    acknowledgement_json, accepted_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    meeting_id,
                    manifest_revision,
                    manifest_sha256,
                    archive_path,
                    acknowledgement_json,
                    accepted_at,
                ),
            )
            connection.commit()
            return acknowledgement

    def attach_media_validation(
        self,
        meeting_id: str,
        manifest_revision: int,
        manifest_sha256: str,
        media_validation: dict[str, Any],
    ) -> dict[str, Any]:
        """Durably add validation evidence to an older same-manifest acknowledgement."""

        with closing_connection(self._connect) as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT manifest_revision, manifest_sha256, acknowledgement_json "
                "FROM acceptances WHERE meeting_id = ?",
                (meeting_id,),
            ).fetchone()
            if row is None or row[0] != manifest_revision or row[1] != manifest_sha256:
                connection.rollback()
                raise QueueConflict("The acceptance changed before media validation could be committed.")
            acknowledgement = json.loads(row[2])
            acknowledgement["media_validation"] = media_validation
            encoded = json.dumps(acknowledgement, sort_keys=True, separators=(",", ":"))
            connection.execute(
                "UPDATE acceptances SET acknowledgement_json = ? WHERE meeting_id = ?",
                (encoded, meeting_id),
            )
            connection.commit()
            return acknowledgement

    def enqueue(
        self,
        meeting_id: str,
        manifest_revision: int,
        manifest_sha256: str,
        archive_path: str,
    ) -> int:
        """Queue directly for tests/tools that do not issue a cleanup acknowledgement."""

        now = self.clock()
        with closing_connection(self._connect) as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute(
                """
                INSERT OR IGNORE INTO jobs (
                    meeting_id, manifest_revision, manifest_sha256, archive_path,
                    state, attempts, available_at, created_at, updated_at
                ) VALUES (?, ?, ?, ?, 'ready', 0, ?, ?, ?)
                """,
                (meeting_id, manifest_revision, manifest_sha256, archive_path, now, now, now),
            )
            row = connection.execute(
                "SELECT id FROM jobs WHERE meeting_id = ? AND manifest_revision = ? "
                "AND manifest_sha256 = ?",
                (meeting_id, manifest_revision, manifest_sha256),
            ).fetchone()
            connection.commit()
        return int(row[0])

    def claim_ready(self, lease_owner: str, lease_seconds: float = 900) -> Job | None:
        if not lease_owner.strip() or lease_seconds <= 0:
            raise ValueError("lease_owner must be nonempty and lease_seconds must be positive.")
        now = self.clock()
        expires = now + lease_seconds
        with closing_connection(self._connect) as connection:
            connection.execute("BEGIN IMMEDIATE")
            # A live lease blocks every other heavy job. An expired lease becomes retryable.
            live = connection.execute(
                "SELECT id FROM jobs WHERE state = 'leased' AND lease_expires_at > ? LIMIT 1",
                (now,),
            ).fetchone()
            if live:
                connection.commit()
                return None
            connection.execute(
                """
                UPDATE jobs
                SET state = 'ready', lease_owner = NULL, lease_expires_at = NULL,
                    available_at = ?, updated_at = ?
                WHERE state = 'leased' AND lease_expires_at <= ?
                """,
                (now, now, now),
            )
            row = connection.execute(
                """
                SELECT * FROM jobs
                WHERE state IN ('ready', 'retry_wait') AND available_at <= ?
                ORDER BY available_at, id
                LIMIT 1
                """,
                (now,),
            ).fetchone()
            if row is None:
                connection.commit()
                return None
            connection.execute(
                """
                UPDATE jobs
                SET state = 'leased', attempts = attempts + 1, lease_owner = ?,
                    lease_expires_at = ?, updated_at = ?
                WHERE id = ?
                """,
                (lease_owner, expires, now, row["id"]),
            )
            claimed = connection.execute("SELECT * FROM jobs WHERE id = ?", (row["id"],)).fetchone()
            connection.commit()
        return self._job(claimed)

    def renew(self, job: Job, lease_seconds: float = 900) -> float:
        expires = self.clock() + lease_seconds
        with closing_connection(self._connect) as connection:
            cursor = connection.execute(
                "UPDATE jobs SET lease_expires_at = ?, updated_at = ? "
                "WHERE id = ? AND state = 'leased' AND lease_owner = ?",
                (expires, self.clock(), job.id, job.lease_owner),
            )
            if cursor.rowcount != 1:
                raise QueueConflict("The job lease is no longer owned by this worker.")
        return expires

    def complete(self, job: Job) -> None:
        self._finish_lease(job, "succeeded", None, None)

    def fail(
        self,
        job: Job,
        error: str,
        *,
        transient: bool,
        base_delay_seconds: float = 60,
        maximum_delay_seconds: float = 3600,
    ) -> float | None:
        if transient:
            exponent = min(30, max(0, job.attempts - 1))
            delay = min(maximum_delay_seconds, base_delay_seconds * (2**exponent))
            available_at = self.clock() + delay
            self._finish_lease(job, "retry_wait", error, available_at)
            return available_at
        self._finish_lease(job, "permanent_failure", error, None)
        return None

    def _finish_lease(
        self,
        job: Job,
        state: str,
        error: str | None,
        available_at: float | None,
    ) -> None:
        now = self.clock()
        with closing_connection(self._connect) as connection:
            cursor = connection.execute(
                """
                UPDATE jobs
                SET state = ?, last_error = ?, available_at = COALESCE(?, available_at),
                    lease_owner = NULL, lease_expires_at = NULL, updated_at = ?
                WHERE id = ? AND state = 'leased' AND lease_owner = ?
                """,
                (state, error, available_at, now, job.id, job.lease_owner),
            )
            if cursor.rowcount != 1:
                raise QueueConflict("The job lease is no longer owned by this worker.")

    def retry_failed(self, meeting_id: str) -> dict[str, Any]:
        """Release the latest failed job without disturbing a live lease.

        This is an explicit operator retry. Attempts remain intact for useful
        diagnostics, and succeeded work is deliberately left succeeded so a
        Notion retry cannot trigger transcription again.
        """

        now = self.clock()
        with closing_connection(self._connect) as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT id, state FROM jobs WHERE meeting_id = ? "
                "ORDER BY manifest_revision DESC, id DESC LIMIT 1",
                (meeting_id,),
            ).fetchone()
            if row is None:
                connection.rollback()
                raise ValueError(f"Meeting {meeting_id} has no processing job.")
            retried = row["state"] in ("retry_wait", "permanent_failure")
            if retried:
                connection.execute(
                    "UPDATE jobs SET state='ready', available_at=?, last_error=NULL, "
                    "lease_owner=NULL, lease_expires_at=NULL, updated_at=? WHERE id=?",
                    (now, now, row["id"]),
                )
            connection.commit()
            return {
                "job_id": int(row["id"]),
                "state": "ready" if retried else str(row["state"]),
                "retried": retried,
            }

    def status(self, meeting_ids: set[str] | None = None) -> dict[str, Any]:
        with closing_connection(self._connect) as connection:
            query = (
                "SELECT id, meeting_id, manifest_revision, manifest_sha256, archive_path, "
                "state, attempts, available_at, lease_owner, lease_expires_at, last_error "
                "FROM jobs"
            )
            parameters: tuple[str, ...] = ()
            if meeting_ids is not None:
                ordered_ids = tuple(sorted(meeting_ids))
                if not ordered_ids:
                    rows = []
                else:
                    placeholders = ",".join("?" for _ in ordered_ids)
                    rows = connection.execute(
                        query + f" WHERE meeting_id IN ({placeholders}) ORDER BY id",
                        ordered_ids,
                    ).fetchall()
            else:
                rows = connection.execute(query + " ORDER BY id", parameters).fetchall()
        jobs = [dict(row) for row in rows]
        counts: dict[str, int] = {}
        for job in jobs:
            counts[job["state"]] = counts.get(job["state"], 0) + 1
        return {"schema_version": 1, "counts": counts, "jobs": jobs}

    @staticmethod
    def _job(row: sqlite3.Row) -> Job:
        return Job(
            id=int(row["id"]),
            meeting_id=str(row["meeting_id"]),
            manifest_revision=int(row["manifest_revision"]),
            manifest_sha256=str(row["manifest_sha256"]),
            archive_path=str(row["archive_path"]),
            state=str(row["state"]),
            attempts=int(row["attempts"]),
            lease_owner=str(row["lease_owner"]),
            lease_expires_at=float(row["lease_expires_at"]),
        )
