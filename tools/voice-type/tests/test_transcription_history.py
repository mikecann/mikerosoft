import importlib.util
from datetime import datetime, timezone
import json
import pathlib
import sys
import tempfile
import unittest


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOLS_DIR / "transcription_history.py"


def load_module():
    spec = importlib.util.spec_from_file_location("transcription_history", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class TranscriptionHistoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_append_returns_newest_first_and_ignores_blank_text(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            history = self.module.TranscriptionHistory(
                pathlib.Path(tmpdir) / "history.jsonl"
            )

            history.append("first recording", "final_only", created_at="2026-08-04T09:00:00+08:00")
            history.append("  ", "final_only", created_at="2026-08-04T09:01:00+08:00")
            history.append("second recording", "precompute", created_at="2026-08-04T09:02:00+08:00")

            entries = history.load()
            self.assertEqual(["second recording", "first recording"], [item["text"] for item in entries])
            self.assertEqual("precompute", entries[0]["mode"])

    def test_load_skips_a_partial_or_corrupt_final_line(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = pathlib.Path(tmpdir) / "history.jsonl"
            path.write_text(
                json.dumps({"created_at": "2026-08-04T09:00:00+08:00", "mode": "final_only", "text": "safe"})
                + "\n{unfinished",
                encoding="utf-8",
            )

            entries = self.module.TranscriptionHistory(path).load()

            self.assertEqual(["safe"], [item["text"] for item in entries])

    def test_retention_keeps_only_the_most_recent_entries(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            history = self.module.TranscriptionHistory(
                pathlib.Path(tmpdir) / "history.jsonl", max_entries=2
            )

            history.append("one", "final_only", created_at="2026-08-04T09:00:00+08:00")
            history.append("two", "final_only", created_at="2026-08-04T09:01:00+08:00")
            history.append("three", "final_only", created_at="2026-08-04T09:02:00+08:00")

            self.assertEqual(["three", "two"], [item["text"] for item in history.load()])

    def test_retention_removes_entries_older_than_thirty_days(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            now = datetime(2026, 8, 4, 10, 0, tzinfo=timezone.utc)
            history = self.module.TranscriptionHistory(
                pathlib.Path(tmpdir) / "history.jsonl",
                retention_days=30,
                clock=lambda: now,
            )
            history.append("too old", "final_only", created_at="2026-07-05T09:59:59+00:00")
            history.append("boundary", "final_only", created_at="2026-07-05T10:00:00+00:00")
            history.append("recent", "final_only", created_at="2026-08-04T09:00:00+00:00")

            self.assertEqual(
                ["recent", "boundary"],
                [item["text"] for item in history.load()],
            )

    def test_load_compacts_expired_entries_from_disk(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = pathlib.Path(tmpdir) / "history.jsonl"
            path.write_text(
                json.dumps({"created_at": "2026-06-01T10:00:00+00:00", "mode": "final_only", "text": "expired"})
                + "\n"
                + json.dumps({"created_at": "2026-08-01T10:00:00+00:00", "mode": "final_only", "text": "kept"})
                + "\n",
                encoding="utf-8",
            )
            history = self.module.TranscriptionHistory(
                path,
                retention_days=30,
                clock=lambda: datetime(2026, 8, 4, 10, 0, tzinfo=timezone.utc),
            )

            self.assertEqual(["kept"], [item["text"] for item in history.load()])
            self.assertNotIn("expired", path.read_text(encoding="utf-8"))

    def test_imports_completed_transcriptions_from_the_existing_log_once(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir = pathlib.Path(tmpdir)
            log_path = tmpdir / "voice-type.log"
            log_path.write_text(
                "2026-08-04 09:10:00  Done (0.20s) [final_only]: 'hello hello'\n"
                "2026-08-04 09:11:00  Nothing to paste (0.10s) [final_only].\n"
                '2026-08-04 09:12:00  Done (0.30s) [precompute]: "it\\\'s safe"\n',
                encoding="utf-8",
            )
            history = self.module.TranscriptionHistory(tmpdir / "history.jsonl")

            self.assertEqual(2, history.import_completed_log(log_path))
            self.assertEqual(0, history.import_completed_log(log_path))
            self.assertEqual(
                ["it's safe", "hello hello"],
                [item["text"] for item in history.load()],
            )

    def test_log_import_deduplicates_live_timestamp_with_timezone(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir = pathlib.Path(tmpdir)
            log_path = tmpdir / "voice-type.log"
            log_path.write_text(
                "2026-08-04 09:10:00  Done (0.20s) [final_only]: 'hello'\n",
                encoding="utf-8",
            )
            history = self.module.TranscriptionHistory(tmpdir / "history.jsonl")
            history.append(
                "hello",
                "final_only",
                created_at="2026-08-04T09:10:00+08:00",
            )

            self.assertEqual(0, history.import_completed_log(log_path))
            self.assertEqual(1, len(history.load()))


if __name__ == "__main__":
    unittest.main()
