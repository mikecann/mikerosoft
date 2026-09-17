from __future__ import annotations

import hashlib
import io
import json
import os
import sys
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
import uuid
import time
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


WORKER_ROOT = Path(__file__).resolve().parents[1] / "worker"
sys.path.insert(0, str(WORKER_ROOT))

from meeting_archive_worker.archive import (  # noqa: E402
    ArchiveConflict,
    ArchiveStore,
)
from meeting_archive_worker.cli import _Heartbeat, main as cli_main  # noqa: E402
from meeting_archive_worker.db import closing_connection  # noqa: E402
from meeting_archive_worker.manifest import (  # noqa: E402
    ManifestError,
    VerifiedFile,
    verify_incoming,
)
from meeting_archive_worker.media_validation import (  # noqa: E402
    MediaValidationError,
    validate_media_files,
)
from meeting_archive_worker.model_processor import (  # noqa: E402
    WhisperPyannoteTranscriber,
    create_playback,
    diarize_waveform,
    extract_speaker_embeddings,
    process as model_process,
)
from meeting_archive_worker.processing import (  # noqa: E402
    TranscriptProcessor,
    timeline_offset,
)
from meeting_archive_worker.queue import JobQueue  # noqa: E402
from meeting_archive_worker.speakers import SpeakerRegistry  # noqa: E402
from meeting_archive_worker.service import PublicationQueue, _ServiceLock, run_once  # noqa: E402


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_bundle(
    root: Path,
    *,
    meeting_id: str | None = None,
    revision: int = 1,
) -> tuple[Path, dict[str, object]]:
    meeting_id = meeting_id or str(uuid.uuid4())
    incoming = root / "incoming" / meeting_id
    (incoming / "media").mkdir(parents=True)
    microphone = b"microphone bytes"
    incoming_audio = b"incoming bytes"
    (incoming / "media" / "microphone-0001.m4a").write_bytes(microphone)
    (incoming / "media" / "incoming-0001.m4a").write_bytes(incoming_audio)
    metadata = {
        "schema_version": 1,
        "meeting_id": meeting_id,
        "manifest_revision": revision,
        "started_at": "2026-09-17T09:00:00+08:00",
        "ended_at": "2026-09-17T09:30:00+08:00",
        "duration_seconds": 1800,
        "timezone": "Australia/Perth",
        "source_app": "Google Meet",
    }
    metadata_bytes = (json.dumps(metadata, sort_keys=True) + "\n").encode()
    (incoming / "metadata.json").write_bytes(metadata_bytes)
    files = [
        {
            "path": "metadata.json",
            "size_bytes": len(metadata_bytes),
            "sha256": sha256(metadata_bytes),
            "kind": "metadata",
        },
        {
            "path": "media/microphone-0001.m4a",
            "size_bytes": len(microphone),
            "sha256": sha256(microphone),
            "kind": "microphone_audio",
        },
        {
            "path": "media/incoming-0001.m4a",
            "size_bytes": len(incoming_audio),
            "sha256": sha256(incoming_audio),
            "kind": "incoming_audio",
        },
    ]
    manifest: dict[str, object] = {
        "schema_version": 1,
        "meeting_id": meeting_id,
        "revision": revision,
        "files": files,
    }
    (incoming / "manifest.json").write_text(
        json.dumps(manifest, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return incoming, manifest


class ManifestTests(unittest.TestCase):
    def test_verifies_finalized_files_and_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            incoming, manifest = write_bundle(Path(temporary))
            verified = verify_incoming(incoming)

            self.assertEqual(verified.meeting_id, manifest["meeting_id"])
            self.assertEqual(verified.revision, 1)
            self.assertEqual(len(verified.files), 3)
            self.assertEqual(verified.started_at.year, 2026)

    def test_rejects_hash_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            incoming, _ = write_bundle(Path(temporary))
            (incoming / "media" / "incoming-0001.m4a").write_bytes(b"outgoing bytes")

            with self.assertRaisesRegex(ManifestError, "SHA-256"):
                verify_incoming(incoming)

    def test_rejects_path_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            incoming, manifest = write_bundle(Path(temporary))
            manifest["files"][1]["path"] = "../outside.m4a"  # type: ignore[index]
            (incoming / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")

            with self.assertRaisesRegex(ManifestError, "relative path"):
                verify_incoming(incoming)

    @unittest.skipUnless(hasattr(os, "symlink"), "symlinks are unavailable")
    def test_rejects_symlinked_file_even_when_hash_matches(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, manifest = write_bundle(root)
            outside = root / "outside.m4a"
            outside.write_bytes(b"incoming bytes")
            target = incoming / "media" / "incoming-0001.m4a"
            target.unlink()
            target.symlink_to(outside)

            with self.assertRaisesRegex(ManifestError, "symbolic link"):
                verify_incoming(incoming)

    def test_rejects_metadata_with_naive_timestamp(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            incoming, manifest = write_bundle(Path(temporary))
            metadata_path = incoming / "metadata.json"
            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
            metadata["started_at"] = "2026-09-17T09:00:00"
            metadata_bytes = json.dumps(metadata, sort_keys=True).encode()
            metadata_path.write_bytes(metadata_bytes)
            manifest["files"][0]["size_bytes"] = len(metadata_bytes)  # type: ignore[index]
            manifest["files"][0]["sha256"] = sha256(metadata_bytes)  # type: ignore[index]
            (incoming / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")

            with self.assertRaisesRegex(ManifestError, "RFC3339"):
                verify_incoming(incoming)

    def test_rejects_nonstandard_json_numbers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            incoming, manifest = write_bundle(Path(temporary))
            metadata_path = incoming / "metadata.json"
            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
            metadata["duration_seconds"] = float("nan")
            metadata_bytes = json.dumps(metadata, sort_keys=True).encode()
            metadata_path.write_bytes(metadata_bytes)
            manifest["files"][0]["size_bytes"] = len(metadata_bytes)  # type: ignore[index]
            manifest["files"][0]["sha256"] = sha256(metadata_bytes)  # type: ignore[index]
            (incoming / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")

            with self.assertRaisesRegex(ManifestError, "nonstandard number"):
                verify_incoming(incoming)


class ArchiveTests(unittest.TestCase):
    def test_media_validation_runs_on_permanent_files_before_acknowledgement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, manifest = write_bundle(root)
            archive = root / "archive"
            archive.mkdir()
            calls = []

            def validate(destination, verified):
                calls.append((destination, verified.meeting_id))
                self.assertTrue((destination / "media" / "microphone-0001.m4a").is_file())
                return {
                    "status": "passed",
                    "full_decode": True,
                    "files": [{"path": "media/microphone-0001.m4a", "duration_seconds": 1800.0}],
                }

            acknowledgement = ArchiveStore(
                archive,
                root / "worker.sqlite3",
                validate_media=True,
                media_validator=validate,
            ).accept(incoming)

            destination = archive / "2026" / "09" / str(manifest["meeting_id"])
            self.assertEqual(calls, [(destination, manifest["meeting_id"])])
            self.assertEqual(acknowledgement["media_validation"]["status"], "passed")
            self.assertTrue(acknowledgement["cleanup_allowed"])

    def test_media_validation_failure_never_commits_cleanup_acknowledgement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, manifest = write_bundle(root)
            archive = root / "archive"
            archive.mkdir()

            def reject(_destination, _verified):
                raise MediaValidationError("audio stream has zero duration")

            with self.assertRaisesRegex(MediaValidationError, "zero duration"):
                ArchiveStore(
                    archive,
                    root / "worker.sqlite3",
                    validate_media=True,
                    media_validator=reject,
                ).accept(incoming)

            self.assertIsNone(JobQueue(root / "worker.sqlite3").acceptance(str(manifest["meeting_id"])))
            self.assertEqual(JobQueue(root / "worker.sqlite3").status()["jobs"], [])

    def test_accept_copies_verified_files_and_durably_queues_job(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, manifest = write_bundle(root)
            archive_root = root / "archive"
            archive_root.mkdir()
            database = root / "worker.sqlite3"

            acknowledgement = ArchiveStore(archive_root, database).accept(incoming)

            destination = archive_root / "2026" / "09" / str(manifest["meeting_id"])
            self.assertTrue((destination / "manifest.json").is_file())
            self.assertTrue((destination / "metadata.json").is_file())
            self.assertEqual(acknowledgement["manifest_revision"], 1)
            self.assertEqual(acknowledgement["queue_job_id"], "1")
            self.assertTrue(acknowledgement["cleanup_allowed"])
            self.assertEqual(len(acknowledgement["verified_files"]), 3)
            jobs = JobQueue(database).status()["jobs"]
            self.assertEqual(len(jobs), 1)
            self.assertEqual(jobs[0]["state"], "ready")

    def test_same_manifest_retry_returns_same_ack_and_one_job(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, _ = write_bundle(root)
            archive = root / "archive"
            archive.mkdir()
            store = ArchiveStore(archive, root / "worker.sqlite3")

            first = store.accept(incoming)
            second = store.accept(incoming)

            self.assertEqual(second, first)
            self.assertEqual(len(JobQueue(root / "worker.sqlite3").status()["jobs"]), 1)

    def test_retry_resumes_a_partial_same_manifest_archive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, manifest = write_bundle(root)
            destination = root / "archive" / "2026" / "09" / str(manifest["meeting_id"])
            destination.mkdir(parents=True)
            manifest_bytes = (incoming / "manifest.json").read_bytes()
            metadata_bytes = (incoming / "metadata.json").read_bytes()
            (destination / "manifest.json").write_bytes(manifest_bytes)
            (destination / "metadata.json").write_bytes(metadata_bytes)
            metadata_inode = (destination / "metadata.json").stat().st_ino

            acknowledgement = ArchiveStore(
                root / "archive",
                root / "worker.sqlite3",
            ).accept(incoming)

            self.assertTrue(destination.joinpath("media", "microphone-0001.m4a").is_file())
            self.assertEqual((destination / "metadata.json").stat().st_ino, metadata_inode)
            self.assertTrue(acknowledgement["cleanup_allowed"])

    def test_retry_after_manifest_write_before_acknowledgement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, manifest = write_bundle(root)
            destination = root / "archive" / "2026" / "09" / str(manifest["meeting_id"])
            destination.mkdir(parents=True)
            (destination / "manifest.json").write_bytes((incoming / "manifest.json").read_bytes())
            acknowledgement = ArchiveStore(root / "archive", root / "worker.sqlite3").accept(incoming)
            self.assertTrue((destination / "metadata.json").is_file())
            self.assertEqual(acknowledgement["queue_job_id"], "1")

    @unittest.skipUnless(hasattr(os, "symlink"), "symlinks are unavailable")
    def test_rejects_symlinked_archive_year_component(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, _ = write_bundle(root)
            archive = root / "archive"
            outside = root / "outside"
            archive.mkdir()
            outside.mkdir()
            (archive / "2026").symlink_to(outside, target_is_directory=True)

            with self.assertRaisesRegex(ArchiveConflict, "path component"):
                ArchiveStore(archive, root / "worker.sqlite3").accept(incoming)

    def test_changed_manifest_for_accepted_meeting_is_a_conflict(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, manifest = write_bundle(root)
            (root / "archive").mkdir()
            store = ArchiveStore(root / "archive", root / "worker.sqlite3")
            store.accept(incoming)
            manifest["revision"] = 2
            metadata_path = incoming / "metadata.json"
            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
            metadata["manifest_revision"] = 2
            metadata_bytes = json.dumps(metadata, sort_keys=True).encode()
            metadata_path.write_bytes(metadata_bytes)
            manifest["files"][0]["size_bytes"] = len(metadata_bytes)  # type: ignore[index]
            manifest["files"][0]["sha256"] = sha256(metadata_bytes)  # type: ignore[index]
            (incoming / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")

            with self.assertRaises(ArchiveConflict):
                store.accept(incoming)

    def test_missing_archive_root_is_rejected_without_creating_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, _ = write_bundle(root)
            archive = root / "missing-volume" / "MeetingArchive"

            with self.assertRaisesRegex(ArchiveConflict, "already exist"):
                ArchiveStore(archive, root / "worker.sqlite3").accept(incoming)

            self.assertFalse(archive.exists())

    def test_same_manifest_retry_rechecks_permanent_files_before_acknowledging(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, manifest = write_bundle(root)
            archive = root / "archive"
            archive.mkdir()
            store = ArchiveStore(archive, root / "worker.sqlite3")
            store.accept(incoming)
            archived_audio = (
                archive
                / "2026"
                / "09"
                / str(manifest["meeting_id"])
                / "media"
                / "incoming-0001.m4a"
            )
            archived_audio.write_bytes(b"corrupt archive")

            with self.assertRaisesRegex(ArchiveConflict, "incomplete or unsafe"):
                store.accept(incoming)


class QueueTests(unittest.TestCase):
    def test_status_filters_processing_and_publication_to_requested_meeting(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "worker.sqlite3"
            queue = JobQueue(database)
            wanted = str(uuid.uuid4())
            other = str(uuid.uuid4())
            wanted_job_id = queue.enqueue(wanted, 1, "a" * 64, temporary)
            other_job_id = queue.enqueue(other, 1, "b" * 64, temporary)
            wanted_job = queue.claim_ready("worker", 60)
            queue.complete(wanted_job)  # type: ignore[arg-type]
            publications = PublicationQueue(database)
            publications.reconcile(queue.status()["jobs"])

            processing = queue.status({wanted})
            publication = publications.status({wanted_job_id})

            self.assertEqual([job["meeting_id"] for job in processing["jobs"]], [wanted])
            self.assertEqual(processing["counts"], {"succeeded": 1})
            self.assertEqual(
                [job["processing_job_id"] for job in publication["jobs"]],
                [wanted_job_id],
            )
            self.assertNotEqual(wanted_job_id, other_job_id)

    def test_explicit_retry_releases_failed_processing_without_stealing_live_lease(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "worker.sqlite3"
            queue = JobQueue(database, clock=lambda: 100.0)
            failed_id = str(uuid.uuid4())
            leased_id = str(uuid.uuid4())
            queue.enqueue(failed_id, 1, "a" * 64, temporary)
            failed = queue.claim_ready("worker", 60)
            queue.fail(failed, "bad media", transient=False)  # type: ignore[arg-type]
            queue.enqueue(leased_id, 1, "b" * 64, temporary)
            leased = queue.claim_ready("worker", 60)

            first = queue.retry_failed(failed_id)
            second = queue.retry_failed(failed_id)
            active = queue.retry_failed(leased_id)

            self.assertTrue(first["retried"])
            self.assertEqual(first["state"], "ready")
            self.assertFalse(second["retried"])
            self.assertEqual(active["state"], "leased")
            self.assertEqual(active["job_id"], leased.id)  # type: ignore[union-attr]

    def test_explicit_publication_retry_does_not_retranscribe_succeeded_processing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "worker.sqlite3"
            queue = JobQueue(database)
            meeting_id = str(uuid.uuid4())
            processing_job_id = queue.enqueue(meeting_id, 1, "a" * 64, temporary)
            processing = queue.claim_ready("worker", 60)
            queue.complete(processing)  # type: ignore[arg-type]
            publications = PublicationQueue(database, clock=lambda: 100.0)
            publications.reconcile(queue.status()["jobs"])
            self.assertFalse(
                publications.run_one(
                    lambda _archive: (_ for _ in ()).throw(RuntimeError("Notion offline")),
                ),
            )

            result = publications.retry_failed(processing_job_id)

            self.assertTrue(result["retried"])
            self.assertEqual(result["state"], "ready")
            self.assertEqual(queue.status({meeting_id})["jobs"][0]["state"], "succeeded")

    def test_closing_connection_commits_rolls_back_and_closes(self) -> None:
        class TrackingConnection(sqlite3.Connection):
            was_closed = False

            def close(self) -> None:
                self.was_closed = True
                super().close()

        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "lifecycle.sqlite3"
            opened: list[TrackingConnection] = []

            def connect() -> TrackingConnection:
                connection = sqlite3.connect(
                    database,
                    isolation_level=None,
                    factory=TrackingConnection,
                )
                opened.append(connection)
                return connection

            with closing_connection(connect) as connection:
                connection.execute("CREATE TABLE values_table (value TEXT NOT NULL)")
                connection.execute("BEGIN IMMEDIATE")
                connection.execute("INSERT INTO values_table VALUES ('committed')")
            self.assertTrue(opened[-1].was_closed)

            with self.assertRaisesRegex(RuntimeError, "roll back"):
                with closing_connection(connect) as connection:
                    connection.execute("BEGIN IMMEDIATE")
                    connection.execute("INSERT INTO values_table VALUES ('rolled back')")
                    raise RuntimeError("roll back this transaction")
            self.assertTrue(opened[-1].was_closed)

            verification = sqlite3.connect(database)
            try:
                values = verification.execute(
                    "SELECT value FROM values_table ORDER BY value",
                ).fetchall()
            finally:
                verification.close()
            self.assertEqual(values, [("committed",)])

    def test_publication_status_exposes_retry_phase_and_error(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "worker.sqlite3"
            JobQueue(database)
            publications = PublicationQueue(database, clock=lambda: 100.0)
            publications.refresh(7, temporary)
            self.assertFalse(
                publications.run_one(
                    lambda _archive: (_ for _ in ()).throw(RuntimeError("Notion offline")),
                ),
            )

            status = publications.status()
            self.assertEqual(status["phase"], "retry_wait")
            self.assertEqual(status["last_error"], "Notion offline")

    @unittest.skipIf(os.name == "nt", "flock assertion is exercised on Bruce/macOS")
    def test_service_process_lock_rejects_a_second_instance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "worker.sqlite3"
            with _ServiceLock(database):
                with self.assertRaisesRegex(RuntimeError, "Another meeting archive service"):
                    with _ServiceLock(database):
                        self.fail("second service lock should not be acquired")

    def test_publication_claim_is_atomic_across_two_service_instances(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "worker.sqlite3"
            queue = JobQueue(database)
            meeting_id = str(uuid.uuid4())
            job_id = queue.enqueue(meeting_id, 1, "a" * 64, temporary)
            job = queue.claim_ready("processor", 60)
            queue.complete(job)  # type: ignore[arg-type]
            jobs = queue.status()["jobs"]
            first = PublicationQueue(database)
            second = PublicationQueue(database)
            first.reconcile(jobs)
            entered = __import__("threading").Event()
            release = __import__("threading").Event()
            results = []

            def publish(_archive):
                entered.set()
                release.wait(2)

            thread = __import__("threading").Thread(
                target=lambda: results.append(first.run_one(publish, lease_seconds=60)),
            )
            thread.start()
            self.assertTrue(entered.wait(1))
            self.assertFalse(second.run_one(publish, lease_seconds=60))
            release.set()
            thread.join(2)
            self.assertEqual(results, [True])
            self.assertEqual(job_id, jobs[0]["id"])

    def test_service_does_not_complete_processing_after_heartbeat_loss(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "worker.sqlite3"
            queue = JobQueue(database)
            meeting_id = str(uuid.uuid4())
            queue.enqueue(meeting_id, 1, "a" * 64, temporary)

            class LostHeartbeat:
                def __init__(self, *_args, **_kwargs):
                    self.error = RuntimeError("lease renewal failed")
                def __enter__(self):
                    return self
                def __exit__(self, *_args):
                    return None

            with patch("meeting_archive_worker.service._Heartbeat", LostHeartbeat):
                result = run_once(database, processor=lambda *_: None, publisher=lambda *_: None)

            self.assertFalse(result["processed"])
            status = JobQueue(database).status()["jobs"][0]
            self.assertEqual(status["state"], "retry_wait")
            self.assertIn("lease renewal failed", status["last_error"])

    def test_notion_failure_does_not_retranscribe_completed_media(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            database = root / "worker.sqlite3"
            queue = JobQueue(database)
            meeting_id = str(uuid.uuid4())
            queue.enqueue(meeting_id, 1, "a" * 64, str(root))
            calls = []
            def processor(_archive, _job):
                calls.append("process")
            def publisher(_archive):
                calls.append("publish")
                raise RuntimeError("Notion offline")
            first = run_once(database, processor=processor, publisher=publisher, lease_seconds=1)
            second = run_once(database, processor=processor, publisher=publisher, lease_seconds=1)
            self.assertTrue(first["processed"])
            self.assertFalse(second["processed"])
            self.assertEqual(calls.count("process"), 1)

    def test_long_job_heartbeat_keeps_second_worker_out(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "worker.sqlite3"
            queue = JobQueue(database)
            for digest in ("a", "b"):
                meeting_id = str(uuid.uuid4())
                queue.enqueue(meeting_id, 1, digest * 64, meeting_id)
            job = queue.claim_ready("slow-worker", lease_seconds=0.15)
            with _Heartbeat(queue, job, 0.15):  # type: ignore[arg-type]
                time.sleep(0.25)
                self.assertIsNone(queue.claim_ready("second-worker", 0.15))
    def test_only_one_heavy_job_can_be_leased_at_a_time(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            database = root / "worker.sqlite3"
            queue = JobQueue(database)
            first_id = str(uuid.uuid4())
            second_id = str(uuid.uuid4())
            queue.enqueue(first_id, 1, "a" * 64, "2026/09/" + first_id)
            queue.enqueue(second_id, 1, "b" * 64, "2026/09/" + second_id)

            first = queue.claim_ready("worker-one", lease_seconds=60)
            second = queue.claim_ready("worker-two", lease_seconds=60)

            self.assertIsNotNone(first)
            self.assertIsNone(second)

    def test_expired_lease_is_recovered_and_transient_failure_retries(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "worker.sqlite3"
            queue = JobQueue(database, clock=lambda: 100.0)
            meeting_id = str(uuid.uuid4())
            queue.enqueue(meeting_id, 1, "a" * 64, "2026/09/" + meeting_id)
            claimed = queue.claim_ready("worker-one", lease_seconds=5)
            self.assertIsNotNone(claimed)

            recovered = JobQueue(database, clock=lambda: 106.0).claim_ready(
                "worker-two",
                lease_seconds=5,
            )
            self.assertEqual(recovered.id, claimed.id)  # type: ignore[union-attr]
            retry_at = JobQueue(database, clock=lambda: 106.0).fail(
                recovered,  # type: ignore[arg-type]
                "temporary",
                transient=True,
                base_delay_seconds=10,
            )
            self.assertEqual(retry_at, 126.0)
            self.assertIsNone(JobQueue(database, clock=lambda: 125.0).claim_ready("early", 5))
            self.assertIsNotNone(JobQueue(database, clock=lambda: 126.0).claim_ready("later", 5))


class ProcessingTests(unittest.TestCase):
    def test_claimed_job_must_match_verified_manifest_before_output_or_models(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, _ = write_bundle(root)
            verified = verify_incoming(incoming)
            matching_job = {
                "meeting_id": verified.meeting_id,
                "manifest_revision": verified.revision,
                "manifest_sha256": verified.manifest_sha256,
            }
            mismatches = {
                "meeting_id": str(uuid.uuid4()),
                "manifest_revision": verified.revision + 1,
                "manifest_sha256": "0" * 64,
            }

            for field, mismatched_value in mismatches.items():
                with self.subTest(field=field):
                    job_values = matching_job | {field: mismatched_value}
                    with patch(
                        "meeting_archive_worker.model_processor._ensure_real_generated_directory",
                    ) as ensure_output, patch(
                        "meeting_archive_worker.model_processor.WhisperPyannoteTranscriber",
                    ) as transcriber:
                        with self.assertRaisesRegex(
                            RuntimeError,
                            "Claimed job does not match the verified archive manifest",
                        ):
                            model_process(incoming, SimpleNamespace(**job_values))

                    ensure_output.assert_not_called()
                    transcriber.assert_not_called()
                    self.assertFalse((incoming / "transcripts").exists())

    def test_valid_json_checkpoint_rebuilds_missing_markdown_without_models(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, _ = write_bundle(root)
            verified = verify_incoming(incoming)
            output = incoming / "transcripts" / "v1"
            output.mkdir(parents=True)
            transcript = {
                "schema_version": 1,
                "meeting_id": verified.meeting_id,
                "manifest_revision": 1,
                "sources": [],
                "turns": [{
                    "start": 1.0,
                    "end": 2.0,
                    "text": "Recovered view",
                    "channel_origin": "microphone",
                }],
                "processing": {"manifest_sha256": verified.manifest_sha256},
            }
            (output / "transcript.json").write_text(json.dumps(transcript), encoding="utf-8")

            with patch.dict(os.environ, {}, clear=True), patch(
                "meeting_archive_worker.model_processor.WhisperPyannoteTranscriber",
                side_effect=AssertionError("checkpoint recovery must not load models"),
            ):
                model_process(
                    incoming,
                    SimpleNamespace(
                        meeting_id=verified.meeting_id,
                        manifest_revision=verified.revision,
                        manifest_sha256=verified.manifest_sha256,
                    ),
                )

            self.assertIn("Recovered view", (output / "transcript.md").read_text(encoding="utf-8"))
            self.assertEqual(list(output.glob("*.part")), [])

    def test_whisper_uses_bounded_cpu_threads_and_vad(self) -> None:
        calls = {}

        class WhisperModel:
            def __init__(self, *_args, **kwargs):
                calls["init"] = kwargs
            def transcribe(self, _path, **kwargs):
                calls["transcribe"] = kwargs
                return [SimpleNamespace(start=0.0, end=1.0, text=" hello ")], None

        module = SimpleNamespace(WhisperModel=WhisperModel)
        with patch.dict(sys.modules, {"faster_whisper": module}), patch.dict(
            os.environ,
            {
                "MEETING_ARCHIVE_ALLOW_TRANSCRIPTION_WITHOUT_DIARIZATION": "1",
                "MEETING_ARCHIVE_WHISPER_CPU_THREADS": "2",
            },
            clear=True,
        ):
            transcriber = WhisperPyannoteTranscriber()
            turns = transcriber.transcribe(Path("unused.m4a"), "microphone")

        self.assertEqual(calls["init"]["cpu_threads"], 2)
        self.assertEqual(calls["transcribe"], {"vad_filter": True})
        self.assertEqual(turns[0]["text"], "hello")

    def test_media_validator_probes_and_fully_decodes_each_declared_stream(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ("video.mov", "microphone.m4a"):
                (root / name).write_bytes(b"fixture")
            manifest = SimpleNamespace(
                files=(
                    VerifiedFile("video.mov", 7, "0" * 64, "video"),
                    VerifiedFile("microphone.m4a", 7, "0" * 64, "microphone_audio"),
                ),
                metadata={"duration_seconds": 10.0},
            )
            probes = iter([
                {"streams": [{"codec_type": "video", "duration": "10.0"}], "format": {"duration": "10.0"}},
                {"streams": [{"codec_type": "audio", "duration": "10.0"}], "format": {"duration": "10.0"}},
            ])
            commands = []

            def run(command, **kwargs):
                commands.append(command)
                if command[0] == "ffprobe":
                    return SimpleNamespace(stdout=json.dumps(next(probes)), stderr="")
                return SimpleNamespace(stdout="", stderr="")

            with patch("meeting_archive_worker.media_validation._executable", side_effect=lambda name: name), patch(
                "meeting_archive_worker.media_validation.subprocess.run",
                side_effect=run,
            ):
                result = validate_media_files(root, manifest)

            self.assertEqual(result["status"], "passed")
            self.assertEqual(len(result["files"]), 2)
            decode_commands = [command for command in commands if command[0] == "ffmpeg"]
            self.assertEqual(len(decode_commands), 2)
            self.assertTrue(all("-xerror" in command for command in decode_commands))

    def test_media_validator_rejects_duration_shorter_than_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "microphone.m4a").write_bytes(b"fixture")
            manifest = SimpleNamespace(
                files=(VerifiedFile("microphone.m4a", 7, "0" * 64, "microphone_audio"),),
                metadata={"duration_seconds": 1800.0},
            )
            probe = {"streams": [{"codec_type": "audio", "duration": "0.1"}], "format": {"duration": "0.1"}}
            with patch("meeting_archive_worker.media_validation._executable", side_effect=lambda name: name), patch(
                "meeting_archive_worker.media_validation.subprocess.run",
                return_value=SimpleNamespace(stdout=json.dumps(probe), stderr=""),
            ):
                with self.assertRaisesRegex(MediaValidationError, "covers only"):
                    validate_media_files(root, manifest)

    def test_diarizer_receives_waveform_dictionary_not_media_path(self) -> None:
        calls = []
        def pipeline(value):
            calls.append(value)
            return "output"
        waveform = object()
        self.assertEqual(diarize_waveform(pipeline, waveform, 16000), "output")
        self.assertEqual(calls, [{"waveform": waveform, "sample_rate": 16000}])

    def test_production_processor_requires_diarization_credentials_before_whisper(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "HF_TOKEN"):
                WhisperPyannoteTranscriber()

    def test_pyannote_array_rows_follow_annotation_label_order(self) -> None:
        class Annotation:
            def labels(self):
                return ["SPEAKER_00", "SPEAKER_01"]
        rows = [[1.0, 0.0], [0.0, 1.0]]
        self.assertEqual(
            extract_speaker_embeddings(rows, Annotation(), "incoming"),
            {"incoming:SPEAKER_00": [1.0, 0.0], "incoming:SPEAKER_01": [0.0, 1.0]},
        )

    def test_transcriber_matches_embedding_rows_to_regular_diarization_labels(self) -> None:
        whisper_calls = {}

        class Annotation:
            def __init__(self, labels):
                self._labels = labels
            def labels(self):
                return self._labels
            def itertracks(self, yield_label=False):
                return []

        class Whisper:
            def transcribe(self, _path, **kwargs):
                whisper_calls.update(kwargs)
                return [], None

        output = SimpleNamespace(
            exclusive_speaker_diarization=Annotation(["EXCLUSIVE_WRONG"]),
            speaker_diarization=Annotation(["SPEAKER_00", "SPEAKER_01"]),
            speaker_embeddings=[[1.0, 0.0], [0.0, 1.0]],
        )
        transcriber = object.__new__(WhisperPyannoteTranscriber)
        transcriber.whisper = Whisper()
        transcriber.diarizer = object()
        transcriber.embeddings = {}
        transcriber._diarize_without_torchcodec = lambda _path: output

        transcriber.transcribe(Path("unused.m4a"), "incoming")

        self.assertEqual(whisper_calls, {"vad_filter": True})
        self.assertEqual(
            transcriber.embeddings,
            {"incoming:SPEAKER_00": [1.0, 0.0], "incoming:SPEAKER_01": [0.0, 1.0]},
        )
    def test_turn_timestamps_must_be_finite(self) -> None:
        with self.assertRaisesRegex(ValueError, "valid start"):
            TranscriptProcessor._validated_turn({"start": float("nan"), "end": 1.0, "text": "bad"})

    def test_shared_session_offset_is_not_double_counted(self) -> None:
        self.assertEqual(timeline_offset(0.4, 0.4), 0.4)
        self.assertEqual(timeline_offset(0.4, None), 0.4)
        self.assertEqual(timeline_offset(0.4, 0.1), 0.4)

    @unittest.skipUnless(shutil.which("ffmpeg"), "ffmpeg is unavailable")
    def test_ffmpeg_playback_mux_runs_on_synthetic_tracks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run([shutil.which("ffmpeg"), "-v", "error", "-f", "lavfi", "-i", "color=black:s=160x90:d=0.5", "-c:v", "libx264", str(root / "video.mov")], check=True)
            for name, frequency in (("mic.m4a", 440), ("incoming.m4a", 660)):
                subprocess.run([shutil.which("ffmpeg"), "-v", "error", "-f", "lavfi", "-i", f"sine=frequency={frequency}:duration=0.5", "-c:a", "aac", str(root / name)], check=True)
            files = (
                VerifiedFile("video.mov", 0, "0" * 64, "video"),
                VerifiedFile("mic.m4a", 0, "0" * 64, "microphone_audio"),
                VerifiedFile("incoming.m4a", 0, "0" * 64, "incoming_audio"),
            )
            output = create_playback(root, SimpleNamespace(files=files))
            self.assertIsNotNone(output)
            self.assertGreater(output.stat().st_size, 0)  # type: ignore[union-attr]

    def test_playback_command_rebuilds_shared_timeline_from_capture_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = (
                VerifiedFile("video.mov", 0, "0" * 64, "video"),
                VerifiedFile("mic.m4a", 0, "0" * 64, "microphone_audio"),
                VerifiedFile("incoming.m4a", 0, "0" * 64, "incoming_audio"),
            )
            commands = []
            def fake_run(command, **_kwargs):
                commands.append(command)
                Path(command[-1]).write_bytes(b"mp4")
            metadata = {"tracks": {
                "video": {"firstOffset": 0.3},
                "microphone": {"firstOffset": 0.2},
                "incoming": {"firstOffset": 0.1},
            }}
            with patch("meeting_archive_worker.model_processor.shutil.which", return_value="ffmpeg"), patch("meeting_archive_worker.model_processor.subprocess.run", side_effect=fake_run):
                create_playback(root, SimpleNamespace(files=files, metadata=metadata))
            self.assertNotIn("-copyts", commands[0])
            filters = next(commands[0][index + 1] for index, value in enumerate(commands[0]) if value == "-filter_complex")
            self.assertIn("[0:v:0]setpts=PTS-STARTPTS+0.3/TB[v]", filters)
            self.assertIn("[1:a:0]asetpts=PTS-STARTPTS,adelay=200:all=1[a1]", filters)
            self.assertIn("[2:a:0]asetpts=PTS-STARTPTS,adelay=100:all=1[a2]", filters)
            self.assertIn("[a1][a2]amix=inputs=2:duration=longest[a]", filters)
            self.assertIn("h264_videotoolbox", commands[0])

    def test_transcript_keeps_channel_origin_separate_from_speaker_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, _ = write_bundle(root)
            verified = verify_incoming(incoming)

            class FakeTranscriber:
                def transcribe(self, path: Path, channel_origin: str):
                    if channel_origin == "microphone":
                        return [{"start": 1.0, "end": 2.0, "text": "hello"}]
                    return [{"start": 0.5, "end": 1.5, "text": "hi", "speaker": "SPEAKER_00"}]

            result = TranscriptProcessor(FakeTranscriber()).process(incoming, verified)

            self.assertEqual([turn["channel_origin"] for turn in result["turns"]], ["incoming", "microphone"])
            self.assertNotIn("speaker", result["turns"][1])
            self.assertEqual(result["turns"][0]["speaker"], "SPEAKER_00")


class CliTests(unittest.TestCase):
    def test_status_cli_filters_a_bounded_meeting_set_and_joins_publication(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "worker.sqlite3"
            queue = JobQueue(database)
            wanted = str(uuid.uuid4())
            other = str(uuid.uuid4())
            wanted_job_id = queue.enqueue(wanted, 1, "a" * 64, temporary)
            queue.enqueue(other, 1, "b" * 64, temporary)
            processing = queue.claim_ready("worker", 60)
            queue.complete(processing)  # type: ignore[arg-type]
            PublicationQueue(database).reconcile(queue.status()["jobs"])

            output = io.StringIO()
            with redirect_stdout(output):
                code = cli_main([
                    "status", "--db", str(database), "--meeting-id", wanted,
                ])
            response = json.loads(output.getvalue())

            self.assertEqual(code, 0)
            self.assertEqual([job["meeting_id"] for job in response["jobs"]], [wanted])
            self.assertEqual(
                [job["processing_job_id"] for job in response["publication"]["jobs"]],
                [wanted_job_id],
            )

    def test_retry_cli_releases_only_failed_stage_and_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "worker.sqlite3"
            queue = JobQueue(database)
            meeting_id = str(uuid.uuid4())
            queue.enqueue(meeting_id, 1, "a" * 64, temporary)
            processing = queue.claim_ready("worker", 60)
            queue.fail(processing, "decoder failed", transient=False)  # type: ignore[arg-type]

            first_output = io.StringIO()
            with redirect_stdout(first_output):
                first_code = cli_main([
                    "retry", "--db", str(database), "--meeting-id", meeting_id,
                ])
            second_output = io.StringIO()
            with redirect_stdout(second_output):
                second_code = cli_main([
                    "retry", "--db", str(database), "--meeting-id", meeting_id,
                ])

            first = json.loads(first_output.getvalue())
            second = json.loads(second_output.getvalue())
            self.assertEqual(first_code, 0)
            self.assertTrue(first["retried"])
            self.assertEqual(first["processing"]["state"], "ready")
            self.assertEqual(second_code, 0)
            self.assertFalse(second["retried"])

    def test_identify_atomically_updates_views_and_queues_publication_refresh(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, _ = write_bundle(root)
            archive = root / "archive"
            archive.mkdir()
            database = root / "worker.sqlite3"
            acknowledgement = ArchiveStore(archive, database).accept(incoming)
            meeting_directory = Path(acknowledgement["archive_path"])
            transcript_directory = meeting_directory / "transcripts" / "v1"
            transcript_directory.mkdir(parents=True)
            transcript = {
                "schema_version": 1,
                "meeting_id": acknowledgement["meeting_id"],
                "manifest_revision": 1,
                "turns": [{
                    "start": 1.0,
                    "end": 2.0,
                    "speaker": "incoming:SPEAKER_00",
                    "channel_origin": "incoming",
                    "text": "Hello",
                }],
            }
            (transcript_directory / "transcript.json").write_text(json.dumps(transcript), encoding="utf-8")
            SpeakerRegistry(database).save_observation(
                acknowledgement["meeting_id"],
                1,
                "incoming:SPEAKER_00",
                [1.0, 0.0],
            )

            output = io.StringIO()
            with redirect_stdout(output):
                code = cli_main([
                    "identify",
                    "--meeting-id", acknowledgement["meeting_id"],
                    "--revision", "1",
                    "--speaker-id", "incoming:SPEAKER_00",
                    "--name", "Kelsie",
                    "--db", str(database),
                ])

            updated = json.loads((transcript_directory / "transcript.json").read_text(encoding="utf-8"))
            self.assertEqual(code, 0)
            self.assertEqual(updated["turns"][0]["name"], "Kelsie")
            self.assertIn("Kelsie", (transcript_directory / "transcript.md").read_text(encoding="utf-8"))
            self.assertEqual(list(transcript_directory.glob("*.part")), [])
            self.assertEqual(PublicationQueue(database).status()["phase"], "ready")

            status_output = io.StringIO()
            with redirect_stdout(status_output):
                self.assertEqual(cli_main(["status", "--db", str(database)]), 0)
            status = json.loads(status_output.getvalue())
            self.assertEqual(status["publication"]["phase"], "ready")
            self.assertIsNone(status["publication"]["last_error"])

    def test_accept_validate_media_flag_is_forwarded_to_archive_store(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, _ = write_bundle(root)
            archive = root / "archive"
            archive.mkdir()
            acknowledgement = {
                "schema_version": 1,
                "meeting_id": str(uuid.uuid4()),
                "cleanup_allowed": True,
            }
            with patch("meeting_archive_worker.cli.ArchiveStore") as store:
                store.return_value.accept.return_value = acknowledgement
                output = io.StringIO()
                with redirect_stdout(output):
                    code = cli_main([
                        "accept", "--incoming", str(incoming), "--archive-root", str(archive),
                        "--db", str(root / "worker.sqlite3"), "--validate-media",
                    ])
            self.assertEqual(code, 0)
            store.assert_called_once_with(archive, root / "worker.sqlite3", validate_media=True)
            self.assertEqual(json.loads(output.getvalue()), acknowledgement)

    def test_swift_accept_argv_returns_decodable_acknowledgement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, _ = write_bundle(root)
            archive = root / "archive"
            archive.mkdir()
            digest = sha256((incoming / "manifest.json").read_bytes())
            output = io.StringIO()
            with redirect_stdout(output):
                exit_code = cli_main([
                    "accept", "--incoming", str(incoming), "--archive-root", str(archive),
                    "--db", str(root / "worker.sqlite3"), "--manifest-sha256", digest,
                ])
            acknowledgement = json.loads(output.getvalue())
            self.assertEqual(exit_code, 0)
            self.assertEqual(acknowledgement["manifest_sha256"], digest)
            self.assertIsInstance(acknowledgement["queue_job_id"], str)

    def test_process_ready_loads_adapter_and_completes_one_job(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            database = root / "worker.sqlite3"
            archive = root / "archive"
            archive.mkdir()
            meeting_id = str(uuid.uuid4())
            JobQueue(database).enqueue(meeting_id, 1, "a" * 64, str(archive))
            (root / "fixture_processor.py").write_text(
                "def process(archive_directory, job):\n"
                "    (archive_directory / 'processed.txt').write_text(str(job.id))\n",
                encoding="utf-8",
            )
            sys.path.insert(0, str(root))
            try:
                output = io.StringIO()
                with redirect_stdout(output):
                    exit_code = cli_main(
                        [
                            "process-ready",
                            "--archive-root",
                            str(archive),
                            "--db",
                            str(database),
                            "--processor",
                            "fixture_processor:process",
                            "--worker-id",
                            "test-worker",
                        ],
                    )
            finally:
                sys.path.remove(str(root))
                sys.modules.pop("fixture_processor", None)

            self.assertEqual(exit_code, 0)
            self.assertTrue(json.loads(output.getvalue())["processed"])
            self.assertEqual((archive / "processed.txt").read_text(encoding="utf-8"), "1")
            self.assertEqual(JobQueue(database).status()["jobs"][0]["state"], "succeeded")

    def test_speaker_names_are_only_stored_by_explicit_identify(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "worker.sqlite3"
            registry = SpeakerRegistry(database)
            meeting_id = str(uuid.uuid4())
            self.assertEqual(registry.assignments(meeting_id, 1), {})
            registry.identify(meeting_id, 1, "incoming:SPEAKER_00", "Kelsie")
            self.assertEqual(
                registry.assignments(meeting_id, 1),
                {"incoming:SPEAKER_00": "Kelsie"},
            )

    def test_voice_suggestion_requires_threshold_and_separation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            registry = SpeakerRegistry(Path(temporary) / "worker.sqlite3")
            registry.enroll_confirmed("Kelsie", [1.0, 0.0])
            registry.enroll_confirmed("Kelsie", [0.99, 0.01])
            registry.enroll_confirmed("James", [0.0, 1.0])
            registry.enroll_confirmed("Wrong model", [1.0, 0.0], model_id="other")
            self.assertEqual(registry.suggest([0.99, 0.01]), "Kelsie")
            self.assertIsNone(registry.suggest([0.7, 0.7]))

    def test_confirmed_observation_enrolls_for_future_reuse(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            registry = SpeakerRegistry(Path(temporary) / "worker.sqlite3")
            meeting_id = str(uuid.uuid4())
            registry.save_observation(meeting_id, 1, "incoming:SPEAKER_00", [1.0, 0.0])
            self.assertTrue(registry.confirm_observation(meeting_id, 1, "incoming:SPEAKER_00", "Kelsie"))
            self.assertEqual(registry.suggest([0.99, 0.01]), "Kelsie")

    def test_identify_cli_enrolls_saved_observation_without_embedding_argument(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "worker.sqlite3"
            meeting_id = str(uuid.uuid4())
            registry = SpeakerRegistry(database)
            registry.save_observation(meeting_id, 1, "incoming:SPEAKER_00", [1.0, 0.0])
            output = io.StringIO()
            with redirect_stdout(output):
                code = cli_main(["identify", "--meeting-id", meeting_id, "--revision", "1", "--speaker-id", "incoming:SPEAKER_00", "--name", "Kelsie", "--db", str(database)])
            self.assertEqual(code, 0)
            self.assertTrue(json.loads(output.getvalue())["voice_profile_enrolled"])


if __name__ == "__main__":
    unittest.main()
