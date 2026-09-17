from __future__ import annotations

import json
import os
import sqlite3
import stat
import tempfile
import unittest
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from pathlib import Path
from unittest.mock import patch

from meeting_archive_worker.queue import JobQueue
from meeting_archive_worker.service import PublicationQueue, run_once
from meeting_archive_worker.speaker_refresh import (
    reconcile_pending_speakers,
    reconcile_speaker_refresh,
    speaker_archive_lock,
)
from meeting_archive_worker.speakers import SpeakerRegistry


class SpeakerRefreshTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.database = self.root / "worker.sqlite"
        JobQueue(self.database)
        self.registry = SpeakerRegistry(self.database)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _observation(
        self,
        meeting_id: str,
        *,
        speaker_id: str = "microphone:SPEAKER_00",
    ) -> None:
        self.registry.save_observation(
            meeting_id,
            1,
            speaker_id,
            [1.0, 0.0],
            "model@1",
        )

    def _pending(self, meeting_id: str) -> tuple | None:
        with closing(sqlite3.connect(self.database)) as connection:
            return connection.execute(
                "SELECT generation, attempts, last_error FROM speaker_refreshes "
                "WHERE meeting_id=? AND manifest_revision=1",
                (meeting_id,),
            ).fetchone()

    def _accepted_archive(self, meeting_id: str) -> tuple[Path, int]:
        archive = self.root / "meetings" / "2026" / "09" / meeting_id
        transcript_directory = archive / "transcripts" / "v1"
        transcript_directory.mkdir(parents=True)
        transcript = {
            "schema_version": 1,
            "meeting_id": meeting_id,
            "manifest_revision": 1,
            "processing": {"manifest_sha256": "a" * 64},
            "turns": [
                {
                    "speaker": "microphone:SPEAKER_00",
                    "channel_origin": "microphone",
                    "start": 0.0,
                    "end": 1.0,
                    "text": "Hello",
                }
            ],
        }
        (transcript_directory / "transcript.json").write_text(
            json.dumps(transcript),
            encoding="utf-8",
        )
        job_id = JobQueue(self.database).enqueue(
            meeting_id,
            1,
            "a" * 64,
            str(archive),
        )
        acknowledgement = {
            "schema_version": 1,
            "meeting_id": meeting_id,
            "manifest_revision": 1,
            "manifest_sha256": "a" * 64,
            "archive_path": str(archive),
            "queue_job_id": str(job_id),
        }
        with closing(sqlite3.connect(self.database)) as connection:
            with connection:
                connection.execute(
                    "INSERT INTO acceptances VALUES (?, ?, ?, ?, ?, ?)",
                    (
                        meeting_id,
                        1,
                        "a" * 64,
                        str(archive),
                        json.dumps(acknowledgement),
                        "2026-09-17T00:00:00Z",
                    ),
                )
        return archive, job_id

    def test_confirmation_commits_assignment_profile_and_refresh_together(self) -> None:
        meeting_id = str(uuid.uuid4())
        self._observation(meeting_id)

        self.assertTrue(
            self.registry.confirm_observation(
                meeting_id,
                1,
                "microphone:SPEAKER_00",
                "Mike Cann",
            )
        )

        with closing(sqlite3.connect(self.database)) as connection:
            assignment = connection.execute(
                "SELECT display_name FROM speaker_assignments WHERE meeting_id=?",
                (meeting_id,),
            ).fetchone()
            profile = connection.execute(
                "SELECT display_name, source_meeting_id FROM voice_profiles "
                "WHERE source_meeting_id=?",
                (meeting_id,),
            ).fetchone()
        self.assertEqual(assignment, ("Mike Cann",))
        self.assertEqual(profile, ("Mike Cann", meeting_id))
        self.assertEqual(self._pending(meeting_id), (1, 0, None))

    def test_first_schema_migration_serializes_concurrent_registry_openers(self) -> None:
        database = self.root / "legacy.sqlite"
        with closing(sqlite3.connect(database)) as connection:
            with connection:
                connection.execute(
                    """CREATE TABLE voice_profiles (
                    display_name TEXT NOT NULL, embedding_json TEXT NOT NULL,
                    confirmed_at TEXT NOT NULL, model_id TEXT NOT NULL,
                    dimension INTEGER NOT NULL)"""
                )

        with ThreadPoolExecutor(max_workers=4) as pool:
            registries = list(pool.map(lambda _: SpeakerRegistry(database), range(8)))

        self.assertEqual(len(registries), 8)
        with closing(sqlite3.connect(database)) as connection:
            columns = {
                row[1] for row in connection.execute("PRAGMA table_info(voice_profiles)")
            }
        self.assertTrue(
            {"source_meeting_id", "source_revision", "source_speaker_id"}
            <= columns
        )

    def test_profile_failure_rolls_back_assignment_and_refresh(self) -> None:
        meeting_id = str(uuid.uuid4())
        self._observation(meeting_id)
        with closing(sqlite3.connect(self.database)) as connection:
            with connection:
                connection.execute(
                    "CREATE TRIGGER reject_profile BEFORE INSERT ON voice_profiles "
                    "BEGIN SELECT RAISE(ABORT, 'profile rejected'); END",
                )

        with self.assertRaises(sqlite3.IntegrityError):
            self.registry.confirm_observation(
                meeting_id,
                1,
                "microphone:SPEAKER_00",
                "Mike Cann",
            )

        self.assertEqual(self.registry.assignments(meeting_id, 1), {})
        self.assertIsNone(self._pending(meeting_id))

    def test_missing_observation_still_records_assignment_and_pending_refresh(self) -> None:
        meeting_id = str(uuid.uuid4())

        self.assertFalse(
            self.registry.confirm_observation(
                meeting_id,
                1,
                "microphone:SPEAKER_00",
                "Mike Cann",
            )
        )

        self.assertEqual(
            self.registry.assignments(meeting_id, 1),
            {"microphone:SPEAKER_00": "Mike Cann"},
        )
        self.assertEqual(self._pending(meeting_id), (1, 0, None))

    def test_refresh_request_increments_generation_and_clears_old_error(self) -> None:
        meeting_id = str(uuid.uuid4())
        self.registry.request_refresh(meeting_id, 1)
        with closing(sqlite3.connect(self.database)) as connection:
            with connection:
                connection.execute(
                    "UPDATE speaker_refreshes SET attempts=2, last_error='old' "
                    "WHERE meeting_id=?",
                    (meeting_id,),
                )

        self.registry.request_refresh(meeting_id, 1)

        self.assertEqual(self._pending(meeting_id), (2, 2, None))

    def test_reconcile_without_acceptance_retains_pending_harmlessly(self) -> None:
        meeting_id = str(uuid.uuid4())
        self.registry.request_refresh(meeting_id, 1)

        self.assertFalse(reconcile_speaker_refresh(self.database, meeting_id, 1))
        self.assertEqual(self._pending(meeting_id), (1, 0, None))

    def test_reconcile_is_successful_when_another_process_already_consumed_pending(self) -> None:
        meeting_id = str(uuid.uuid4())

        self.assertTrue(reconcile_speaker_refresh(self.database, meeting_id, 1))

    def test_reconcile_is_successful_when_pending_is_consumed_while_waiting_for_lock(self) -> None:
        meeting_id = str(uuid.uuid4())
        self._accepted_archive(meeting_id)

        with patch(
            "meeting_archive_worker.speaker_refresh._pending_generation",
            side_effect=[1, None],
        ):
            self.assertTrue(reconcile_speaker_refresh(self.database, meeting_id, 1))

    def test_reconcile_rebuilds_transcript_queues_publication_then_clears(self) -> None:
        meeting_id = str(uuid.uuid4())
        archive, job_id = self._accepted_archive(meeting_id)
        self._observation(meeting_id)
        self.registry.confirm_observation(
            meeting_id,
            1,
            "microphone:SPEAKER_00",
            "Mike Cann",
        )

        self.assertTrue(reconcile_speaker_refresh(self.database, meeting_id, 1))

        transcript = json.loads(
            (archive / "transcripts" / "v1" / "transcript.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(transcript["turns"][0]["name"], "Mike Cann")
        self.assertEqual(transcript["turns"][0]["name_source"], "confirmed")
        self.assertIn("Mike Cann", (archive / "transcripts" / "v1" / "transcript.md").read_text())
        self.assertIsNone(self._pending(meeting_id))
        publication = PublicationQueue(self.database).status({job_id})
        self.assertEqual(publication["phase"], "ready")
        lock_path = archive / "transcripts" / "v1" / ".speaker-refresh.lock"
        self.assertTrue(stat.S_ISREG(lock_path.stat().st_mode))
        self.assertEqual(stat.S_IMODE(lock_path.stat().st_mode), 0o600)

    def test_new_generation_requested_during_reconcile_is_not_cleared(self) -> None:
        meeting_id = str(uuid.uuid4())
        archive, _ = self._accepted_archive(meeting_id)
        self._observation(meeting_id)
        self.registry.confirm_observation(
            meeting_id,
            1,
            "microphone:SPEAKER_00",
            "Mike Cann",
        )
        from meeting_archive_worker import model_processor

        original_write = model_processor._write_transcript_artifacts

        def write_and_request(output, transcript):
            original_write(output, transcript)
            self.registry.request_refresh(meeting_id, 1)

        with patch.object(model_processor, "_write_transcript_artifacts", write_and_request):
            self.assertTrue(reconcile_speaker_refresh(self.database, meeting_id, 1))

        self.assertEqual(self._pending(meeting_id), (2, 0, None))
        self.assertTrue((archive / "transcripts" / "v1" / "transcript.json").is_file())

    def test_pending_sweep_retains_failure_and_continues_other_meetings(self) -> None:
        broken_id = str(uuid.uuid4())
        broken_archive, _ = self._accepted_archive(broken_id)
        (broken_archive / "transcripts" / "v1" / "transcript.json").write_text("not json")
        self.registry.request_refresh(broken_id, 1)

        valid_id = str(uuid.uuid4())
        self._accepted_archive(valid_id)
        self._observation(valid_id)
        self.registry.confirm_observation(
            valid_id,
            1,
            "microphone:SPEAKER_00",
            "Mike Cann",
        )

        result = reconcile_pending_speakers(self.database)

        self.assertEqual(result["processed"], 1)
        self.assertEqual(result["remaining"], 1)
        broken = self._pending(broken_id)
        self.assertEqual(broken[1], 1)
        self.assertIn("JSONDecodeError", broken[2])
        self.assertIsNone(self._pending(valid_id))

    def test_service_reconciles_pending_speakers_before_processing(self) -> None:
        meeting_id = str(uuid.uuid4())
        JobQueue(self.database).enqueue(meeting_id, 1, "b" * 64, str(self.root))
        events: list[str] = []

        with patch(
            "meeting_archive_worker.speaker_refresh.reconcile_pending_speakers",
            side_effect=lambda _database: events.append("refresh") or {},
        ):
            run_once(
                self.database,
                processor=lambda *_: events.append("process"),
                publisher=lambda *_: events.append("publish"),
            )

        self.assertEqual(events[0:2], ["refresh", "process"])

    def test_archive_lock_is_owner_only(self) -> None:
        archive = self.root / "archive"
        (archive / "transcripts" / "v1").mkdir(parents=True)

        with speaker_archive_lock(archive, 1) as lock_path:
            self.assertEqual(
                lock_path,
                archive / "transcripts" / "v1" / ".speaker-refresh.lock",
            )
            self.assertEqual(stat.S_IMODE(lock_path.stat().st_mode), 0o600)

    @unittest.skipIf(os.name == "nt", "same-process Windows file-lock semantics differ")
    def test_archive_lock_wait_is_bounded(self) -> None:
        archive = self.root / "archive"
        (archive / "transcripts" / "v1").mkdir(parents=True)

        with speaker_archive_lock(archive, 1):
            with self.assertRaises(TimeoutError):
                with speaker_archive_lock(archive, 1, timeout_seconds=0.01):
                    self.fail("the second lock unexpectedly succeeded")


if __name__ == "__main__":
    unittest.main()
