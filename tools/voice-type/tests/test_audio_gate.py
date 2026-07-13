import importlib.util
import pathlib
import sys
import unittest


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOLS_DIR / "audio_gate.py"


def load_module():
    spec = importlib.util.spec_from_file_location("audio_gate", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class AudioGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_skips_short_near_silent_audio(self):
        self.assertTrue(
            self.module.should_skip_short_low_level_audio(
                duration_sec=0.4,
                rms=0.001,
                peak=0.01,
            )
        )

    def test_keeps_long_quiet_audio(self):
        self.assertFalse(
            self.module.should_skip_short_low_level_audio(
                duration_sec=1.2,
                rms=0.001,
                peak=0.01,
            )
        )

    def test_keeps_short_audio_with_clear_peak(self):
        self.assertFalse(
            self.module.should_skip_short_low_level_audio(
                duration_sec=0.4,
                rms=0.001,
                peak=0.2,
            )
        )


if __name__ == "__main__":
    unittest.main()
