"""Stable worker loop with independent media and Notion retry stages."""

from __future__ import annotations

import argparse
import os
import socket
import sqlite3
import time
import uuid
from contextlib import AbstractContextManager
from pathlib import Path

from .cli import _Heartbeat
from .db import closing_connection
from .notion import publish
from .processor import process
from .queue import JobQueue, QueueConflict


class PublicationQueue:
    def __init__(self, database: Path | str, clock=time.time):
        self.database = Path(database)
        self.clock = clock
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            connection.execute(
                """CREATE TABLE IF NOT EXISTS publication_jobs (
                processing_job_id INTEGER PRIMARY KEY, archive_path TEXT NOT NULL,
                state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
                available_at REAL NOT NULL, last_error TEXT,
                lease_owner TEXT, lease_expires_at REAL,
                refresh_requested INTEGER NOT NULL DEFAULT 0)""",
            )
            columns = {row[1] for row in connection.execute("PRAGMA table_info(publication_jobs)")}
            if "lease_owner" not in columns:
                connection.execute("ALTER TABLE publication_jobs ADD COLUMN lease_owner TEXT")
            if "lease_expires_at" not in columns:
                connection.execute("ALTER TABLE publication_jobs ADD COLUMN lease_expires_at REAL")
            if "refresh_requested" not in columns:
                connection.execute(
                    "ALTER TABLE publication_jobs ADD COLUMN refresh_requested INTEGER NOT NULL DEFAULT 0",
                )

    def reconcile(self, jobs: list[dict]) -> None:
        now = self.clock()
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            for job in jobs:
                if job["state"] == "succeeded":
                    connection.execute(
                        "INSERT OR IGNORE INTO publication_jobs "
                        "(processing_job_id, archive_path, state, attempts, available_at, last_error) "
                        "VALUES (?, ?, 'ready', 0, ?, NULL)",
                        (job["id"], job["archive_path"], now),
                    )

    def refresh(self, processing_job_id: int, archive_path: str) -> None:
        """Request publication after a durable transcript correction."""

        now = self.clock()
        with closing_connection(
            lambda: sqlite3.connect(self.database, timeout=30, isolation_level=None),
        ) as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute(
                "INSERT OR IGNORE INTO publication_jobs "
                "(processing_job_id, archive_path, state, attempts, available_at, last_error) "
                "VALUES (?, ?, 'ready', 0, ?, NULL)",
                (processing_job_id, archive_path, now),
            )
            connection.execute(
                "UPDATE publication_jobs SET archive_path=?, "
                "state=CASE WHEN state='publishing' THEN state ELSE 'ready' END, "
                "available_at=CASE WHEN state='publishing' THEN available_at ELSE ? END, "
                "last_error=CASE WHEN state='publishing' THEN last_error ELSE NULL END, "
                "refresh_requested=CASE WHEN state='publishing' THEN 1 ELSE 0 END "
                "WHERE processing_job_id=?",
                (archive_path, now, processing_job_id),
            )
            connection.commit()

    def retry_failed(self, processing_job_id: int) -> dict | None:
        """Release an errored publication while preserving completed media work."""

        now = self.clock()
        with closing_connection(
            lambda: sqlite3.connect(self.database, timeout=30, isolation_level=None),
        ) as connection:
            connection.row_factory = sqlite3.Row
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT state, last_error FROM publication_jobs WHERE processing_job_id=?",
                (processing_job_id,),
            ).fetchone()
            if row is None:
                connection.commit()
                return None
            retried = row["state"] == "retry_wait" and row["last_error"] is not None
            if retried:
                connection.execute(
                    "UPDATE publication_jobs SET state='ready', available_at=?, last_error=NULL, "
                    "lease_owner=NULL, lease_expires_at=NULL WHERE processing_job_id=?",
                    (now, processing_job_id),
                )
            connection.commit()
            return {
                "processing_job_id": processing_job_id,
                "state": "ready" if retried else str(row["state"]),
                "retried": retried,
            }

    def status(self, processing_job_ids: set[int] | None = None) -> dict:
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            connection.row_factory = sqlite3.Row
            query = (
                "SELECT processing_job_id, archive_path, state, attempts, available_at, "
                "last_error, lease_owner, lease_expires_at, refresh_requested "
                "FROM publication_jobs"
            )
            if processing_job_ids is not None:
                ordered_ids = tuple(sorted(processing_job_ids))
                if not ordered_ids:
                    rows = []
                else:
                    placeholders = ",".join("?" for _ in ordered_ids)
                    rows = connection.execute(
                        query + f" WHERE processing_job_id IN ({placeholders}) "
                        "ORDER BY processing_job_id",
                        ordered_ids,
                    ).fetchall()
            else:
                rows = connection.execute(query + " ORDER BY processing_job_id").fetchall()
        jobs = [dict(row) for row in rows]
        counts: dict[str, int] = {}
        for job in jobs:
            counts[job["state"]] = counts.get(job["state"], 0) + 1
        active = None
        for phase in ("publishing", "retry_wait", "ready"):
            active = next((job for job in jobs if job["state"] == phase), None)
            if active is not None:
                break
        latest_error = next(
            (job["last_error"] for job in reversed(jobs) if job["last_error"]),
            None,
        )
        return {
            "counts": counts,
            "phase": active["state"] if active else ("succeeded" if jobs else "not_queued"),
            "last_error": latest_error,
            "jobs": jobs,
        }

    def run_one(self, publisher=publish, *, lease_seconds: float = 900) -> bool:
        if lease_seconds <= 0:
            raise ValueError("publication lease_seconds must be positive")
        now = self.clock()
        owner = f"{socket.gethostname()}:{uuid.uuid4()}"
        with closing_connection(
            lambda: sqlite3.connect(self.database, timeout=30, isolation_level=None),
        ) as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute(
                "UPDATE publication_jobs SET state='retry_wait', available_at=?, "
                "lease_owner=NULL, lease_expires_at=NULL "
                "WHERE state='publishing' AND (lease_expires_at IS NULL OR lease_expires_at<=?)",
                (now, now),
            )
            row = connection.execute(
                "SELECT processing_job_id, archive_path, attempts FROM publication_jobs "
                "WHERE state IN ('ready','retry_wait') AND available_at<=? ORDER BY processing_job_id LIMIT 1",
                (now,),
            ).fetchone()
            if row is None:
                connection.commit()
                return False
            cursor = connection.execute(
                "UPDATE publication_jobs SET state='publishing', attempts=attempts+1, "
                "lease_owner=?, lease_expires_at=?, refresh_requested=0 "
                "WHERE processing_job_id=? AND state IN ('ready','retry_wait')",
                (owner, now + lease_seconds, row[0]),
            )
            if cursor.rowcount != 1:
                connection.rollback()
                return False
            connection.commit()
        try:
            publisher(Path(row[1]))
        except Exception as error:
            delay = min(3600, 60 * (2 ** min(6, row[2])))
            with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
                connection.execute(
                    "UPDATE publication_jobs SET state='retry_wait', available_at=?, last_error=?, "
                    "lease_owner=NULL, lease_expires_at=NULL "
                    "WHERE processing_job_id=? AND state='publishing' AND lease_owner=?",
                    (self.clock() + delay, str(error), row[0], owner),
                )
            return False
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            cursor = connection.execute(
                "UPDATE publication_jobs SET "
                "state=CASE WHEN refresh_requested=1 THEN 'ready' ELSE 'succeeded' END, "
                "available_at=CASE WHEN refresh_requested=1 THEN ? ELSE available_at END, "
                "last_error=NULL, refresh_requested=0, "
                "lease_owner=NULL, lease_expires_at=NULL "
                "WHERE processing_job_id=? AND state='publishing' AND lease_owner=?",
                (self.clock(), row[0], owner),
            )
        return cursor.rowcount == 1


def run_once(database: Path, processor=process, publisher=publish, lease_seconds: float = 900) -> dict:
    queue = JobQueue(database)
    job = queue.claim_ready(f"{socket.gethostname()}:{uuid.uuid4()}", lease_seconds)
    processed = False
    if job is not None:
        try:
            os.environ["MEETING_ARCHIVE_WORKER_DB"] = str(database)
            os.environ.setdefault("MEETING_ARCHIVE_SCRATCH", str(database.parent / "runtime" / "tmp"))
            for key, value in {
                "DO_NOT_TRACK": "1",
                "HF_HUB_DISABLE_TELEMETRY": "1",
                "PYANNOTE_METRICS_ENABLED": "0",
                "TOKENIZERS_PARALLELISM": "false",
                "OMP_NUM_THREADS": "2",
                "MKL_NUM_THREADS": "2",
                "MEETING_ARCHIVE_TORCH_THREADS": "2",
                "MEETING_ARCHIVE_WHISPER_CPU_THREADS": "2",
            }.items():
                os.environ.setdefault(key, value)
            with _Heartbeat(queue, job, lease_seconds) as heartbeat:
                processor(Path(job.archive_path), job)
            if heartbeat.error is not None:
                raise QueueConflict(f"Lost the job lease during processing: {heartbeat.error}")
            queue.complete(job)
            processed = True
        except Exception as error:
            try:
                queue.fail(job, str(error), transient=True)
            except QueueConflict:
                pass
    publications = PublicationQueue(database)
    publications.reconcile(queue.status()["jobs"])
    published = publications.run_one(publisher)
    return {"processed": processed, "published": published}


class _ServiceLock(AbstractContextManager["_ServiceLock"]):
    """Keep one long-running service process per database on Bruce."""

    def __init__(self, database: Path):
        self.path = database.with_name(database.name + ".service.lock")
        self.file = None

    def __enter__(self) -> "_ServiceLock":
        self.file = self.path.open("a+b")
        try:
            if os.name == "nt":
                import msvcrt

                self.file.seek(0, os.SEEK_END)
                if self.file.tell() == 0:
                    self.file.write(b"0")
                    self.file.flush()
                self.file.seek(0)
                msvcrt.locking(self.file.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl

                fcntl.flock(self.file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (OSError, IOError) as error:
            self.file.close()
            self.file = None
            raise RuntimeError(f"Another meeting archive service already owns {self.path}.") from error
        return self

    def __exit__(self, *_args: object) -> None:
        if self.file is None:
            return
        if os.name == "nt":
            import msvcrt

            self.file.seek(0)
            msvcrt.locking(self.file.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl

            fcntl.flock(self.file.fileno(), fcntl.LOCK_UN)
        self.file.close()
        self.file = None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--poll-seconds", type=float, default=15)
    args = parser.parse_args()
    with _ServiceLock(args.db):
        while True:
            run_once(args.db)
            time.sleep(max(1, args.poll_seconds))


if __name__ == "__main__":
    raise SystemExit(main())
