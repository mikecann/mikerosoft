"""Heavy processing runs in a child process so the idle service stays small."""

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "worker"))

from meeting_archive_worker.service import process_isolated  # noqa: E402


def write_pid(archive_path, job):
    Path(archive_path, "child.pid").write_text(str(os.getpid()))


def explode(archive_path, job):
    raise ValueError(f"bad job {job}")


def hard_exit(archive_path, job):
    os._exit(3)


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


if __name__ == "__main__":
    unittest.main()
