"""Meeting renames live beside the immutable, manifest-hashed metadata."""

from __future__ import annotations

import hashlib
import io
import json
import sys
import tempfile
import unittest
import uuid
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path


WORKER_ROOT = Path(__file__).resolve().parents[1] / "worker"
sys.path.insert(0, str(WORKER_ROOT))

from meeting_archive_worker.archive import ArchiveStore  # noqa: E402
from meeting_archive_worker.cli import main as cli_main  # noqa: E402
from meeting_archive_worker.notion import publish  # noqa: E402
from meeting_archive_worker.queue import JobQueue  # noqa: E402
from meeting_archive_worker.service import PublicationQueue  # noqa: E402
from meeting_archive_worker.titles import effective_title, normalize_title  # noqa: E402
from test_notion import PLAYBACK_BASE, MockTransport  # noqa: E402
from test_worker import write_bundle  # noqa: E402


def tree_digest(root: Path) -> dict[str, str]:
    return {
        str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


class RenameTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.archive_root = self.root / "archive"
        self.archive_root.mkdir()
        self.database = self.root / "worker.sqlite3"
        incoming, _ = write_bundle(self.root)
        acknowledgement = ArchiveStore(self.archive_root, self.database).accept(incoming)
        self.meeting_id = acknowledgement["meeting_id"]
        self.archive = Path(acknowledgement["archive_path"])
        self.job_id = int(acknowledgement["queue_job_id"])

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def rename(self, title: str, meeting_id: str | None = None) -> tuple[int, dict | None, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = cli_main([
                "rename",
                "--meeting-id", meeting_id or self.meeting_id,
                "--title", title,
                "--archive-root", str(self.archive_root),
                "--db", str(self.database),
            ])
        output = json.loads(stdout.getvalue()) if stdout.getvalue() else None
        return code, output, stderr.getvalue()

    def complete_processing(self) -> None:
        queue = JobQueue(self.database)
        queue.complete(queue.claim_ready("worker", 60))  # type: ignore[arg-type]

    def test_rename_writes_title_file_without_touching_manifest_files(self) -> None:
        before = tree_digest(self.archive)

        code, output, _ = self.rename("  Quarterly planning  ")

        self.assertEqual(code, 0)
        self.assertEqual(
            output,
            {"schema_version": 1, "meeting_id": self.meeting_id, "title": "Quarterly planning"},
        )
        record = json.loads((self.archive / "title.json").read_text(encoding="utf-8"))
        self.assertEqual(record["schema_version"], 1)
        self.assertEqual(record["title"], "Quarterly planning")
        self.assertIsInstance(record["updated_at"], str)
        after = tree_digest(self.archive)
        after.pop("title.json")
        self.assertEqual(after, before)

    def test_rename_is_idempotent(self) -> None:
        self.rename("Quarterly planning")
        first = (self.archive / "title.json").read_bytes()

        code, output, _ = self.rename("Quarterly planning")

        self.assertEqual(code, 0)
        self.assertEqual(output["title"], "Quarterly planning")  # type: ignore[index]
        self.assertEqual((self.archive / "title.json").read_bytes(), first)

    def test_invalid_titles_are_rejected_without_writing(self) -> None:
        for title in ("", "   ", "x" * 201, "Line\nbreak", "Tab\there", "Bell\x07"):
            with self.subTest(title=title):
                code, output, stderr = self.rename(title)
                self.assertEqual(code, 2)
                self.assertIsNone(output)
                self.assertIn("title", json.loads(stderr)["message"].lower())
        self.assertFalse((self.archive / "title.json").exists())

    def test_unknown_meeting_fails_with_clear_error(self) -> None:
        unknown = str(uuid.uuid4())

        code, output, stderr = self.rename("Anything", unknown)

        self.assertEqual(code, 2)
        self.assertIsNone(output)
        error = json.loads(stderr)
        self.assertIn(unknown, error["message"])
        self.assertIn("not accepted", error["message"])

    def test_rename_queues_republication_for_succeeded_processing(self) -> None:
        self.complete_processing()
        publications = PublicationQueue(self.database)
        publications.reconcile(JobQueue(self.database).status()["jobs"])
        self.assertTrue(publications.run_one(lambda _archive: None))
        self.assertEqual(publications.status({self.job_id})["phase"], "succeeded")

        code, _, _ = self.rename("Quarterly planning")

        self.assertEqual(code, 0)
        job = publications.status({self.job_id})["jobs"][0]
        self.assertEqual(job["state"], "ready")
        self.assertEqual(job["archive_path"], str(self.archive))

    def test_rename_before_processing_leaves_publication_to_normal_flow(self) -> None:
        code, _, _ = self.rename("Quarterly planning")

        self.assertEqual(code, 0)
        self.assertEqual(PublicationQueue(self.database).status()["jobs"], [])


class EffectiveTitleTests(unittest.TestCase):
    def test_prefers_title_file_and_falls_back_to_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary)
            metadata = {"title": "Meeting 23 Sep 2026 at 6:47 am"}
            self.assertEqual(effective_title(archive, metadata), "Meeting 23 Sep 2026 at 6:47 am")
            self.assertIsNone(effective_title(archive, {}))

            (archive / "title.json").write_text("not json", encoding="utf-8")
            self.assertEqual(effective_title(archive, metadata), "Meeting 23 Sep 2026 at 6:47 am")

            (archive / "title.json").write_text(
                json.dumps({"schema_version": 1, "title": "Renamed", "updated_at": "2026-09-29T00:00:00Z"}),
                encoding="utf-8",
            )
            self.assertEqual(effective_title(archive, metadata), "Renamed")
            self.assertEqual(effective_title(archive, {}), "Renamed")

    def test_normalize_title_trims_and_bounds(self) -> None:
        self.assertEqual(normalize_title("  Planning  "), "Planning")
        self.assertEqual(len(normalize_title("x" * 200)), 200)
        with self.assertRaises(ValueError):
            normalize_title("x" * 201)


class RenamedPublicationTests(unittest.TestCase):
    def test_notion_page_and_header_use_renamed_title(self) -> None:
        from test_notion import write_archive

        with tempfile.TemporaryDirectory() as temporary:
            archive = write_archive(Path(temporary))
            transport = MockTransport()
            first = publish(archive, token="token", data_source="source", transport=transport,
                            playback_base_url=PLAYBACK_BASE)
            (archive / "title.json").write_text(
                json.dumps({"schema_version": 1, "title": "Launch review", "updated_at": "2026-09-29T00:00:00Z"}),
                encoding="utf-8",
            )

            second = publish(archive, token="token", data_source="source", transport=transport,
                             playback_base_url=PLAYBACK_BASE)

            self.assertNotEqual(first["content_fingerprint"], second["content_fingerprint"])
            name = transport.pages[0]["properties"]["Name"]["title"]
            self.assertEqual("".join(item["text"]["content"] for item in name), "Launch review")
            header = next(block for block in transport.children["page-1"] if block["type"] == "heading_1")
            self.assertTrue(header["heading_1"]["rich_text"][0]["text"]["content"].startswith("Launch review"))


if __name__ == "__main__":
    unittest.main()
