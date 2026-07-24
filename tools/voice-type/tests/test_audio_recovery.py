import importlib.util
import pathlib
import sys
import unittest


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOLS_DIR / "audio_recovery.py"


def load_module():
    spec = importlib.util.spec_from_file_location("audio_recovery", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class AudioRecoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_close_timeout_blocks_another_stream_open(self):
        recovery = self.module.AudioBackendRecovery()

        recovery.note_close_timeout()

        self.assertFalse(recovery.can_open_stream)
        self.assertTrue(recovery.restart_required)

    def test_successful_close_keeps_backend_usable(self):
        recovery = self.module.AudioBackendRecovery()

        recovery.note_close_finished()

        self.assertTrue(recovery.can_open_stream)
        self.assertFalse(recovery.restart_required)

    def test_restart_runs_after_current_dictation_finishes(self):
        recovery = self.module.AudioBackendRecovery()
        recovery.note_close_timeout()
        events = []

        recovery.finish_then_recover(
            lambda: events.append("dictation finished"),
            lambda: events.append("app restarted"),
        )

        self.assertEqual(events, ["dictation finished", "app restarted"])

    def test_restart_still_runs_if_finalization_fails(self):
        recovery = self.module.AudioBackendRecovery()
        recovery.note_close_timeout()
        events = []

        def fail_finalization():
            events.append("dictation attempted")
            raise RuntimeError("transcription failed")

        with self.assertRaisesRegex(RuntimeError, "transcription failed"):
            recovery.finish_then_recover(
                fail_finalization,
                lambda: events.append("app restarted"),
            )

        self.assertEqual(events, ["dictation attempted", "app restarted"])

    def test_earlier_overlapping_dictation_does_not_claim_later_recovery(self):
        recovery = self.module.AudioBackendRecovery()
        recovery.note_close_timeout()
        events = []

        recovery.finish_then_recover(
            lambda: events.append("earlier dictation finished"),
            lambda: events.append("app restarted"),
            requested=False,
        )

        self.assertEqual(events, ["earlier dictation finished"])

    def test_only_one_finalizer_can_start_the_restart(self):
        recovery = self.module.AudioBackendRecovery()
        recovery.note_close_timeout()
        events = []

        for _ in range(2):
            recovery.finish_then_recover(
                lambda: events.append("dictation finished"),
                lambda: events.append("app restarted"),
                requested=True,
            )

        self.assertEqual(
            events,
            ["dictation finished", "app restarted", "dictation finished"],
        )


if __name__ == "__main__":
    unittest.main()
