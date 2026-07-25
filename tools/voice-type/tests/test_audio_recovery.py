import importlib.util
import pathlib
import sys
import threading
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

    def test_open_failure_blocks_retry_until_process_restart(self):
        recovery = self.module.AudioBackendRecovery()

        recovery.note_open_failure()

        self.assertFalse(recovery.can_open_stream)
        self.assertTrue(recovery.restart_required)

    def test_open_failure_claims_only_one_automatic_restart(self):
        recovery = self.module.AudioBackendRecovery()
        recovery.note_open_failure()
        events = []

        for _ in range(2):
            recovery.recover_if_required(
                lambda: events.append("app restarted"),
            )

        self.assertEqual(events, ["app restarted"])

    def test_failed_restart_releases_claim_for_a_later_retry(self):
        recovery = self.module.AudioBackendRecovery()
        recovery.note_open_failure()
        events = []

        first_result = recovery.recover_if_required(
            lambda: events.append("first attempt") or False,
        )
        second_result = recovery.recover_if_required(
            lambda: events.append("second attempt"),
        )

        self.assertFalse(first_result)
        self.assertTrue(second_result)
        self.assertEqual(events, ["first attempt", "second attempt"])

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

    def test_restart_waits_for_all_overlapping_finalizations(self):
        recovery = self.module.AudioBackendRecovery()
        events = []

        finish_earlier = recovery.prepare_finish(
            lambda: events.append("earlier dictation finished"),
            lambda: events.append("app restarted"),
        )
        recovery.note_close_timeout()
        finish_later = recovery.prepare_finish(
            lambda: events.append("later dictation finished"),
            lambda: events.append("app restarted"),
        )

        finish_earlier()
        self.assertEqual(events, ["earlier dictation finished"])

        finish_later()

        self.assertEqual(
            events,
            [
                "earlier dictation finished",
                "later dictation finished",
                "app restarted",
            ],
        )

    def test_only_one_finalizer_can_start_the_restart(self):
        recovery = self.module.AudioBackendRecovery()
        recovery.note_close_timeout()
        events = []

        for _ in range(2):
            recovery.finish_then_recover(
                lambda: events.append("dictation finished"),
                lambda: events.append("app restarted"),
            )

        self.assertEqual(
            events,
            ["dictation finished", "app restarted", "dictation finished"],
        )

    def test_key_down_cannot_restart_while_previous_dictation_is_finishing(self):
        recovery = self.module.AudioBackendRecovery()
        recovery.note_close_timeout()
        finish_started = threading.Event()
        allow_finish = threading.Event()
        events = []

        def finish():
            events.append("dictation started")
            finish_started.set()
            allow_finish.wait(timeout=2)
            events.append("dictation finished")

        finish_job = recovery.prepare_finish(
            finish,
            lambda: events.append("app restarted"),
        )
        thread = threading.Thread(target=finish_job)
        thread.start()
        self.assertTrue(finish_started.wait(timeout=2))

        restarted_on_key_down = recovery.recover_if_required(
            lambda: events.append("restarted on key down"),
        )

        self.assertFalse(restarted_on_key_down)
        self.assertNotIn("restarted on key down", events)
        allow_finish.set()
        thread.join(timeout=2)
        self.assertFalse(thread.is_alive())
        self.assertEqual(
            events,
            ["dictation started", "dictation finished", "app restarted"],
        )


if __name__ == "__main__":
    unittest.main()
