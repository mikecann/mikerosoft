import importlib.util
import os
import pathlib
import tempfile
import unittest
from unittest import mock


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOLS_DIR / "platform_mac.py"


def load_module():
    spec = importlib.util.spec_from_file_location("platform_mac", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class PlatformMacStartupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_set_startup_enable_writes_launch_agent_and_loads_service(self):
        with tempfile.TemporaryDirectory() as tmp_home:
            agents_dir = os.path.join(tmp_home, "Library", "LaunchAgents")
            expected_plist = os.path.join(
                agents_dir,
                "com.mikerosoft.voice-type.plist",
            )
            expected_script_dir = str(TOOLS_DIR)
            expected_python = os.path.join(expected_script_dir, ".venv", "bin", "python3")
            expected_app = os.path.join(expected_script_dir, "voice-type.py")
            expected_log = os.path.join(expected_script_dir, "voice-type.log")
            domain = "gui/501"
            service = "gui/501/com.mikerosoft.voice-type"

            with mock.patch.object(self.module.os.path, "expanduser", return_value=agents_dir):
                with mock.patch.object(self.module.os, "getuid", return_value=501):
                    with mock.patch.object(self.module.subprocess, "run") as run_mock:
                        self.module.set_startup(True, log=None)

            self.assertTrue(os.path.exists(expected_plist))
            with open(expected_plist, "r", encoding="utf-8") as f:
                content = f.read()

            self.assertIn(f"<string>{expected_python}</string>", content)
            self.assertIn(f"<string>{expected_app}</string>", content)
            self.assertIn(f"<string>{expected_log}</string>", content)
            self.assertIn("<key>RunAtLoad</key>", content)
            self.assertIn("<key>KeepAlive</key>", content)
            self.assertIn("<key>SuccessfulExit</key>", content)
            self.assertIn("<false/>", content)

            run_mock.assert_has_calls(
                [
                    mock.call(["launchctl", "bootout", service], check=False),
                    mock.call(["launchctl", "bootstrap", domain, expected_plist], check=False),
                    mock.call(["launchctl", "kickstart", "-k", service], check=False),
                ],
                any_order=False,
            )

    def test_set_startup_disable_unloads_and_deletes_plist(self):
        with tempfile.TemporaryDirectory() as tmp_home:
            agents_dir = os.path.join(tmp_home, "Library", "LaunchAgents")
            plist_path = os.path.join(
                agents_dir,
                "com.mikerosoft.voice-type.plist",
            )
            os.makedirs(os.path.dirname(plist_path), exist_ok=True)
            with open(plist_path, "w", encoding="utf-8") as f:
                f.write("<plist/>")

            service = "gui/501/com.mikerosoft.voice-type"
            with mock.patch.object(self.module.os.path, "expanduser", return_value=agents_dir):
                with mock.patch.object(self.module.os, "getuid", return_value=501):
                    with mock.patch.object(self.module.subprocess, "run") as run_mock:
                        self.module.set_startup(False, log=None)

            self.assertFalse(os.path.exists(plist_path))
            run_mock.assert_called_once_with(["launchctl", "bootout", service], check=False)


if __name__ == "__main__":
    unittest.main()
