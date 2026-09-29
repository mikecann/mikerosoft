"""The staged copy of a bundle is removed once its archive copy is durable."""

from __future__ import annotations

import hashlib
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch


WORKER_ROOT = Path(__file__).resolve().parents[1] / "worker"
sys.path.insert(0, str(WORKER_ROOT))

from meeting_archive_worker.cli import main as cli_main  # noqa: E402
from meeting_archive_worker.queue import JobQueue  # noqa: E402
from test_worker import write_bundle  # noqa: E402


class StagingCleanupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        # Bruce's layout: MeetingArchive/{incoming,meetings}.
        self.incoming_root = self.root / "incoming"
        self.archive_root = self.root / "meetings"
        self.incoming_root.mkdir()
        self.archive_root.mkdir()
        self.database = self.root / "worker.sqlite3"
        self.sources = self.root / "sources"
        bundle, _ = write_bundle(self.sources)
        self.bundle = bundle
        self.meeting_id = bundle.name
        self.manifest_sha256 = hashlib.sha256((bundle / "manifest.json").read_bytes()).hexdigest()
        self.staging = self.incoming_root / self.meeting_id / "r1"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def stage(self, staging: Path | None = None) -> Path:
        """Copy the bundle into staging, as the Mac's rsync does."""
        staging = staging or self.staging
        shutil.copytree(self.bundle, staging)
        return staging

    def accept(self, incoming: Path | None = None) -> tuple[int, dict | None, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = cli_main([
                "accept",
                "--incoming", str(incoming or self.staging),
                "--archive-root", str(self.archive_root),
                "--db", str(self.database),
                "--manifest-sha256", self.manifest_sha256,
            ])
        output = json.loads(stdout.getvalue()) if stdout.getvalue() else None
        return code, output, stderr.getvalue()

    def test_accept_removes_staged_revision_and_empty_meeting_directory(self) -> None:
        self.stage()

        code, acknowledgement, _ = self.accept()

        self.assertEqual(code, 0)
        self.assertTrue(acknowledgement["cleanup_allowed"])  # type: ignore[index]
        self.assertFalse(self.staging.exists())
        self.assertFalse((self.incoming_root / self.meeting_id).exists())
        self.assertTrue(self.incoming_root.is_dir())
        archive = Path(acknowledgement["archive_path"])  # type: ignore[index]
        self.assertTrue((archive / "media" / "microphone-0001.m4a").is_file())
        self.assertEqual(JobQueue(self.database).status()["counts"], {"ready": 1})

    def test_meeting_directory_with_other_revisions_is_kept(self) -> None:
        self.stage()
        other = self.incoming_root / self.meeting_id / "r2"
        other.mkdir()

        self.accept()

        self.assertFalse(self.staging.exists())
        self.assertTrue(other.is_dir())

    def test_resent_bundle_after_ambiguous_success_returns_original_receipt(self) -> None:
        self.stage()
        _, first, _ = self.accept()

        # The Mac lost the response, so it re-rsyncs and accepts again.
        self.stage()
        code, second, _ = self.accept()

        self.assertEqual(code, 0)
        self.assertEqual(second, first)
        self.assertFalse(self.staging.exists())

    def test_accept_retry_without_staging_returns_original_receipt(self) -> None:
        self.stage()
        _, first, _ = self.accept()

        code, second, _ = self.accept()

        self.assertEqual(code, 0)
        self.assertEqual(second, first)

    def test_missing_staging_for_unaccepted_meeting_still_fails(self) -> None:
        code, output, stderr = self.accept()

        self.assertEqual(code, 2)
        self.assertIsNone(output)
        self.assertIn("error", json.loads(stderr))

    def test_removal_failure_still_prints_receipt(self) -> None:
        self.stage()

        with patch("meeting_archive_worker.archive.shutil.rmtree", side_effect=OSError("busy")):
            code, acknowledgement, stderr = self.accept()

        self.assertEqual(code, 0)
        self.assertTrue(acknowledgement["cleanup_allowed"])  # type: ignore[index]
        self.assertIn("busy", stderr)
        self.assertTrue(self.staging.is_dir())

    def test_symlinked_meeting_directory_is_never_followed(self) -> None:
        elsewhere = self.root / "elsewhere"
        self.stage(elsewhere / "r1")
        (self.incoming_root / self.meeting_id).symlink_to(elsewhere, target_is_directory=True)

        code, _, _ = self.accept()

        self.assertEqual(code, 0)
        self.assertTrue((elsewhere / "r1" / "manifest.json").is_file())
        self.assertTrue(os.path.islink(self.incoming_root / self.meeting_id))

    def test_bundle_outside_the_incoming_layout_is_left_alone(self) -> None:
        code, _, _ = self.accept(self.bundle)

        self.assertEqual(code, 0)
        self.assertTrue((self.bundle / "manifest.json").is_file())


if __name__ == "__main__":
    unittest.main()
