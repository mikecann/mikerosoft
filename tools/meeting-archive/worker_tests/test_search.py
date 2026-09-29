"""Case-insensitive transcript search across accepted meetings."""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
import uuid
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch


WORKER_ROOT = Path(__file__).resolve().parents[1] / "worker"
sys.path.insert(0, str(WORKER_ROOT))

from meeting_archive_worker.cli import main as cli_main  # noqa: E402
from meeting_archive_worker.queue import JobQueue  # noqa: E402


class SearchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.archive_root = self.root / "meetings"
        self.archive_root.mkdir()
        self.database = self.root / "worker.sqlite3"
        JobQueue(self.database)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def meeting(self, started_at: str, turns: list[dict], *, title: str | None = None, revision: int = 1) -> str:
        meeting_id = str(uuid.uuid4())
        archive = self.archive_root / "2026" / "09" / meeting_id
        transcripts = archive / "transcripts" / f"v{revision}"
        transcripts.mkdir(parents=True)
        metadata = {"schema_version": 1, "meeting_id": meeting_id, "manifest_revision": revision,
                    "started_at": started_at, "duration_seconds": 60}
        if title is not None:
            metadata["title"] = title
        (archive / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
        (transcripts / "transcript.json").write_text(json.dumps({
            "schema_version": 1, "meeting_id": meeting_id, "manifest_revision": revision, "turns": turns,
        }), encoding="utf-8")
        JobQueue(self.database).record_acceptance(
            meeting_id=meeting_id,
            manifest_revision=revision,
            manifest_sha256="a" * 64,
            archive_path=str(archive),
            accepted_at="2026-09-29T00:00:00Z",
            verified_files=[],
        )
        return meeting_id

    def search(self, *arguments: str) -> tuple[int, dict | None, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = cli_main([
                "search", *arguments,
                "--archive-root", str(self.archive_root),
                "--db", str(self.database),
            ])
        output = json.loads(stdout.getvalue()) if stdout.getvalue() else None
        return code, output, stderr.getvalue()

    def test_finds_case_insensitive_matches_newest_meeting_first(self) -> None:
        older = self.meeting("2026-09-20T09:00:00+08:00", [
            {"start": 1.5, "end": 2.0, "speaker": "microphone:SPEAKER_00", "text": "The BUDGET is tight."},
        ], title="Old meeting")
        newer = self.meeting("2026-09-25T09:00:00+08:00", [
            {"start": 3.0, "end": 4.0, "speaker": "incoming:SPEAKER_01", "name": "Kelsie",
             "text": "Budget review next week"},
            {"start": 5.0, "end": 6.0, "text": "Unrelated"},
        ], title="New meeting")
        self.meeting("2026-09-27T09:00:00+08:00", [{"start": 0, "end": 1, "text": "Nothing here"}])

        code, output, _ = self.search("--query=  budget ")

        self.assertEqual(code, 0)
        self.assertEqual(output["schema_version"], 1)  # type: ignore[index]
        results = output["results"]  # type: ignore[index]
        self.assertEqual([result["meeting_id"] for result in results], [newer, older])
        self.assertEqual(results[0]["title"], "New meeting")
        self.assertEqual(results[0]["matches"], [
            {"start_seconds": 3.0, "speaker": "Kelsie", "text": "Budget review next week"},
        ])
        self.assertEqual(results[1]["matches"][0]["speaker"], "microphone:SPEAKER_00")

    def test_title_uses_rename_and_speaker_may_be_null(self) -> None:
        meeting_id = self.meeting("2026-09-25T09:00:00+08:00", [{"start": 0, "end": 1, "text": "roadmap"}],
                                  title="Meeting 23 Sep 2026 at 6:47 am")
        archive = self.archive_root / "2026" / "09" / meeting_id
        (archive / "title.json").write_text(
            json.dumps({"schema_version": 1, "title": "Roadmap sync", "updated_at": "2026-09-29T00:00:00Z"}),
            encoding="utf-8",
        )

        _, output, _ = self.search("--query", "ROADMAP")

        result = output["results"][0]  # type: ignore[index]
        self.assertEqual(result["title"], "Roadmap sync")
        self.assertIsNone(result["matches"][0]["speaker"])

    def test_limits_matches_per_meeting_and_meetings(self) -> None:
        for day in range(1, 5):
            self.meeting(f"2026-09-0{day}T09:00:00Z", [
                {"start": float(index), "end": index + 1.0, "text": f"alpha {index}"} for index in range(9)
            ])

        _, output, _ = self.search("--query=alpha", "--limit", "3")

        results = output["results"]  # type: ignore[index]
        self.assertEqual(len(results), 3)
        self.assertTrue(all(len(result["matches"]) == 5 for result in results))
        self.assertEqual(results[0]["matches"][0]["text"], "alpha 0")

    def test_skips_oversized_and_unreadable_transcripts(self) -> None:
        good = self.meeting("2026-09-25T09:00:00Z", [{"start": 0, "end": 1, "text": "needle"}])
        broken = self.meeting("2026-09-26T09:00:00Z", [{"start": 0, "end": 1, "text": "needle"}])
        broken_path = self.archive_root / "2026" / "09" / broken / "transcripts" / "v1" / "transcript.json"
        broken_path.write_text("not json", encoding="utf-8")
        large = self.meeting("2026-09-27T09:00:00Z", [{"start": 0, "end": 1, "text": "needle"}])

        with patch("meeting_archive_worker.search.MAX_TRANSCRIPT_BYTES", 1000):
            large_path = self.archive_root / "2026" / "09" / large / "transcripts" / "v1" / "transcript.json"
            large_path.write_text(large_path.read_text() + " " * 2000, encoding="utf-8")
            code, output, _ = self.search("--query=needle")

        self.assertEqual(code, 0)
        self.assertEqual([result["meeting_id"] for result in output["results"]], [good])  # type: ignore[index]

    def test_rejects_short_long_or_missing_queries(self) -> None:
        for query in ("", " a ", "x" * 201):
            with self.subTest(query=query):
                code, output, stderr = self.search(f"--query={query}")
                self.assertEqual(code, 2)
                self.assertIsNone(output)
                self.assertIn("query", json.loads(stderr)["message"].lower())

    def test_rejects_out_of_range_limit(self) -> None:
        code, _, stderr = self.search("--query=budget", "--limit", "0")

        self.assertEqual(code, 2)
        self.assertIn("limit", json.loads(stderr)["message"].lower())

    def test_no_matches_returns_empty_results(self) -> None:
        self.meeting("2026-09-25T09:00:00Z", [{"start": 0, "end": 1, "text": "hello"}])

        code, output, _ = self.search("--query=goodbye")

        self.assertEqual(code, 0)
        self.assertEqual(output, {"schema_version": 1, "results": []})


if __name__ == "__main__":
    unittest.main()
