import importlib.util
import pathlib
import sys
import unittest


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOLS_DIR / "recording_session.py"


def load_module():
    spec = importlib.util.spec_from_file_location("recording_session", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class RecordingSessionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_failed_start_does_not_finalize_on_key_release(self):
        session = self.module.RecordingSession()

        session.note_start_result(False)

        self.assertFalse(session.finish_on_release())

    def test_successful_start_finalizes_exactly_once(self):
        session = self.module.RecordingSession()
        session.note_start_result(True)

        self.assertTrue(session.finish_on_release())
        self.assertFalse(session.finish_on_release())

    def test_failed_start_clears_frames_from_previous_recording(self):
        buffer = self.module.AudioFrameBuffer()
        buffer.mark_started()
        buffer.append("old audio")

        buffer.reset_for_start_attempt()

        self.assertEqual([], buffer.stop())

    def test_stopped_frames_are_drained_exactly_once(self):
        buffer = self.module.AudioFrameBuffer()
        buffer.reset_for_start_attempt()
        buffer.mark_started()
        buffer.append("new audio")

        self.assertEqual(["new audio"], buffer.stop())
        self.assertEqual([], buffer.stop())


if __name__ == "__main__":
    unittest.main()
