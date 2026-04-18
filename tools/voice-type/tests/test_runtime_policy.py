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

    def test_windows_keeps_mic_stream_open(self):
        self.assertTrue(self.module.should_keep_mic_stream_open("win32"))

    def test_macos_does_not_keep_mic_stream_open(self):
        self.assertFalse(self.module.should_keep_mic_stream_open("darwin"))

    def test_other_platforms_default_to_not_keeping_mic_open(self):
        self.assertFalse(self.module.should_keep_mic_stream_open("linux"))


if __name__ == "__main__":
    unittest.main()
