import importlib.util
import pathlib
import sys
import unittest


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOLS_DIR / "runtime_policy.py"


def load_module():
    spec = importlib.util.spec_from_file_location("runtime_policy", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class RuntimePolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_windows_does_not_keep_mic_stream_open(self):
        self.assertFalse(self.module.should_keep_mic_stream_open("win32"))

    def test_macos_does_not_keep_mic_stream_open(self):
        self.assertFalse(self.module.should_keep_mic_stream_open("darwin"))

    def test_other_platforms_default_to_not_keeping_mic_open(self):
        self.assertFalse(self.module.should_keep_mic_stream_open("linux"))

    def test_final_only_still_streams_preview_text(self):
        # "Final only" controls when text is injected into the target app.
        # It must not disable the live transcript shown in the overlay.
        self.assertTrue(self.module.should_stream_preview("final_only"))

    def test_all_output_modes_stream_preview_text(self):
        for mode in ("hybrid", "stabilized", "precompute"):
            with self.subTest(mode=mode):
                self.assertTrue(self.module.should_stream_preview(mode))

    def test_long_loop_gap_is_treated_as_system_resume(self):
        self.assertTrue(
            self.module.should_restart_after_loop_gap(
                platform_name="darwin",
                previous_wall_time=100.0,
                current_wall_time=131.0,
            )
        )

    def test_windows_resume_does_not_force_a_process_restart(self):
        self.assertFalse(
            self.module.should_restart_after_loop_gap(
                platform_name="win32",
                previous_wall_time=100.0,
                current_wall_time=131.0,
            )
        )

    def test_normal_loop_gap_does_not_restart(self):
        self.assertFalse(
            self.module.should_restart_after_loop_gap(
                platform_name="darwin",
                previous_wall_time=100.0,
                current_wall_time=100.02,
            )
        )

    def test_clock_adjustment_backwards_does_not_restart(self):
        self.assertFalse(
            self.module.should_restart_after_loop_gap(
                platform_name="darwin",
                previous_wall_time=100.0,
                current_wall_time=90.0,
            )
        )


if __name__ == "__main__":
    unittest.main()
