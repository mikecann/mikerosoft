import importlib.util
import pathlib
import sys
import threading
import time
import unittest


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOLS_DIR / "operation_watchdog.py"


def load_module():
    spec = importlib.util.spec_from_file_location("operation_watchdog", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class OperationWatchdogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_completed_operation_does_not_time_out(self):
        timed_out = threading.Event()
        watchdog = self.module.OperationWatchdog(
            timeout_seconds=0.2,
            on_timeout=timed_out.set,
            name="test operation",
        )

        watchdog.start()
        watchdog.complete()

        self.assertFalse(timed_out.wait(0.3))

    def test_blocked_operation_times_out_exactly_once(self):
        calls = []
        timed_out = threading.Event()

        def on_timeout():
            calls.append("timeout")
            timed_out.set()

        watchdog = self.module.OperationWatchdog(
            timeout_seconds=0.02,
            on_timeout=on_timeout,
            name="test operation",
        )

        watchdog.start()
        watchdog.start()
        self.assertTrue(timed_out.wait(1))
        time.sleep(0.03)

        self.assertEqual(["timeout"], calls)

    def test_finalization_deadline_scales_with_recording_length(self):
        self.assertEqual(30.0, self.module.finalization_timeout_seconds(5.0))
        self.assertEqual(80.0, self.module.finalization_timeout_seconds(40.0))


if __name__ == "__main__":
    unittest.main()
