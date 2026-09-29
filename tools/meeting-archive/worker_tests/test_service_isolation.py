"""Heavy processing runs in a child process so the idle service stays small."""

import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "worker"))

from meeting_archive_worker.cli import PermanentProcessingError  # noqa: E402
from meeting_archive_worker.service import (  # noqa: E402
    _exit_when_orphaned,
    _processing_budget,
    process_isolated,
)


def write_pid(archive_path, job):
    Path(archive_path, "child.pid").write_text(str(os.getpid()))


def explode(archive_path, job):
    raise ValueError(f"bad job {job}")


def hard_exit(archive_path, job):
    os._exit(3)


def hang(archive_path, job):
    time.sleep(600)


def reject_permanently(archive_path, job):
    raise PermanentProcessingError("unsupported codec")


class ProcessIsolatedTest(unittest.TestCase):
    def test_runs_in_a_separate_process(self):
        with tempfile.TemporaryDirectory() as directory:
            process_isolated(Path(directory), "job-1", target=write_pid)
            child = int(Path(directory, "child.pid").read_text())
            self.assertNotEqual(child, os.getpid())

    def test_child_errors_reach_the_parent(self):
        with self.assertRaisesRegex(RuntimeError, "ValueError: bad job job-2"):
            process_isolated(Path("."), "job-2", target=explode)

    def test_a_crashed_child_is_reported(self):
        with self.assertRaisesRegex(RuntimeError, "exited with code 3"):
            process_isolated(Path("."), "job-3", target=hard_exit)

    def test_a_permanent_error_keeps_its_kind_across_the_process_boundary(self):
        with self.assertRaisesRegex(PermanentProcessingError, "unsupported codec"):
            process_isolated(Path("."), "job-4", target=reject_permanently)

    def test_a_hung_child_is_stopped_at_its_time_budget(self):
        started = time.monotonic()
        with self.assertRaisesRegex(RuntimeError, "time budget"):
            process_isolated(Path("."), "job-5", target=hang, timeout=1)
        self.assertLess(time.monotonic() - started, 30)

    def test_time_budget_scales_with_media_duration(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(_processing_budget(Path(directory)), 3600)
            Path(directory, "metadata.json").write_text(json.dumps({"duration_seconds": 4920}))
            self.assertEqual(_processing_budget(Path(directory)), 6 * 4920)
            Path(directory, "metadata.json").write_text(json.dumps({"duration_seconds": 60}))
            self.assertEqual(_processing_budget(Path(directory)), 3600)

    def test_child_exits_once_its_parent_is_gone(self):
        parents = iter([100, 100, 1])
        exits = []
        _exit_when_orphaned(100, interval=0, getppid=lambda: next(parents), exit=exits.append)
        self.assertEqual(exits, [1])


if __name__ == "__main__":
    unittest.main()
