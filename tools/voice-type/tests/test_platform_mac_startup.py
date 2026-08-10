import importlib.util
import os
import pathlib
import tempfile
import unittest
from unittest import mock
from types import SimpleNamespace


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
            install_dir = os.path.join(
                tmp_home,
                "Library",
                "Application Support",
                "Voice Type",
            )
            log_dir = os.path.join(tmp_home, "Library", "Logs", "Voice Type")
            install_dir = os.path.realpath(install_dir)
            log_dir = os.path.realpath(log_dir)
            expected_plist = os.path.join(
                agents_dir,
                "com.mikerosoft.voice-type.plist",
            )
            os.makedirs(os.path.join(install_dir, ".venv", "bin"))
            expected_launcher = os.path.join(
                install_dir,
                ".venv",
                "bin",
                "Voice Type",
            )
            pathlib.Path(expected_launcher).touch()
            expected_app = os.path.join(install_dir, "voice-type.py")
            pathlib.Path(expected_app).touch()
            expected_wrapper = os.path.join(install_dir, "launch-voice-type-mac.sh")
            pathlib.Path(expected_wrapper).touch()
            pathlib.Path(expected_wrapper).chmod(0o755)
            expected_log = os.path.join(log_dir, "launchd.log")
            domain = "gui/501"
            service = "gui/501/com.mikerosoft.voice-type"

            with mock.patch.object(
                self.module.os.path,
                "expanduser",
                side_effect=lambda value: value if os.path.isabs(value) else agents_dir,
            ):
                with mock.patch.object(self.module.os, "getuid", return_value=501, create=True):
                    with mock.patch.dict(
                        self.module.os.environ,
                        {
                            "VOICE_TYPE_INSTALL_DIR": install_dir,
                            "VOICE_TYPE_LOG_DIR": log_dir,
                        },
                        clear=False,
                    ):
                        with mock.patch.object(self.module.subprocess, "run") as run_mock:
                            self.module.set_startup(True, log=None)

            self.assertTrue(os.path.exists(expected_plist))
            with open(expected_plist, "r", encoding="utf-8") as f:
                content = f.read()

            self.assertIn(f"<string>{expected_wrapper}</string>", content)
            self.assertNotIn(f"<string>{expected_app}</string>", content)
            self.assertIn(f"<string>{expected_log}</string>", content)
            self.assertNotIn(".codex/worktrees", content)
            self.assertIn("<key>RunAtLoad</key>", content)
            self.assertIn("<key>KeepAlive</key>", content)
            self.assertIn("<key>SuccessfulExit</key>", content)
            self.assertIn("<false/>", content)
            self.assertIn("<key>ThrottleInterval</key>", content)

            run_mock.assert_has_calls(
                [
                    mock.call(["launchctl", "bootout", service], check=False),
                    mock.call(["launchctl", "bootstrap", domain, expected_plist], check=False),
                    mock.call(["launchctl", "kickstart", "-k", service], check=False),
                ],
                any_order=False,
            )

    def test_set_startup_enable_rejects_missing_native_launcher(self):
        with tempfile.TemporaryDirectory() as tmp_home:
            agents_dir = os.path.join(tmp_home, "Library", "LaunchAgents")
            install_dir = str(pathlib.Path(tmp_home) / "voice-type")
            messages = []

            with mock.patch.object(
                self.module.os.path,
                "expanduser",
                side_effect=lambda value: value if os.path.isabs(value) else agents_dir,
            ):
                with mock.patch.object(self.module.os, "getuid", return_value=501, create=True):
                    with mock.patch.dict(
                        self.module.os.environ,
                        {"VOICE_TYPE_INSTALL_DIR": install_dir},
                        clear=False,
                    ):
                        with mock.patch.object(self.module.subprocess, "run") as run_mock:
                            self.module.set_startup(True, log=messages.append)

            self.assertEqual(0, run_mock.call_count)
            self.assertTrue(any("Run setup first" in message for message in messages))

    def test_set_startup_enable_rejects_missing_installed_worker(self):
        with tempfile.TemporaryDirectory() as tmp_home:
            agents_dir = os.path.join(tmp_home, "Library", "LaunchAgents")
            install_dir = str(pathlib.Path(tmp_home) / "voice-type")
            launcher = pathlib.Path(install_dir) / ".venv" / "bin" / "Voice Type"
            launcher.parent.mkdir(parents=True)
            launcher.touch()
            wrapper = pathlib.Path(install_dir) / "launch-voice-type-mac.sh"
            wrapper.touch()
            wrapper.chmod(0o755)
            messages = []

            with mock.patch.object(
                self.module.os.path,
                "expanduser",
                side_effect=lambda value: value if os.path.isabs(value) else agents_dir,
            ):
                with mock.patch.object(self.module.os, "getuid", return_value=501, create=True):
                    with mock.patch.dict(
                        self.module.os.environ,
                        {"VOICE_TYPE_INSTALL_DIR": install_dir},
                        clear=False,
                    ):
                        with mock.patch.object(self.module.subprocess, "run") as run_mock:
                            self.module.set_startup(True, log=messages.append)

            self.assertEqual(0, run_mock.call_count)
            self.assertTrue(any("installed worker missing" in message for message in messages))

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
                with mock.patch.object(self.module.os, "getuid", return_value=501, create=True):
                    with mock.patch.object(self.module.subprocess, "run") as run_mock:
                        self.module.set_startup(False, log=None)

            self.assertFalse(os.path.exists(plist_path))
            run_mock.assert_called_once_with(["launchctl", "bootout", service], check=False)

    def test_set_startup_disable_unloads_even_when_plist_is_missing(self):
        with tempfile.TemporaryDirectory() as tmp_home:
            agents_dir = os.path.join(tmp_home, "Library", "LaunchAgents")
            service = "gui/501/com.mikerosoft.voice-type"

            with mock.patch.object(self.module.os.path, "expanduser", return_value=agents_dir):
                with mock.patch.object(self.module.os, "getuid", return_value=501, create=True):
                    with mock.patch.object(self.module.subprocess, "run") as run_mock:
                        self.module.set_startup(False, log=None)

            run_mock.assert_called_once_with(["launchctl", "bootout", service], check=False)

    def test_activate_settings_window_brings_accessory_app_forward(self):
        ns_app = mock.Mock()
        appkit = SimpleNamespace(NSApp=ns_app)

        with mock.patch.dict("sys.modules", {"AppKit": appkit}):
            self.module.activate_settings_window()

        ns_app.activateIgnoringOtherApps_.assert_called_once_with(True)

    def test_restart_supervisor_active_identifies_this_launchd_process(self):
        with mock.patch.dict(
            self.module.os.environ,
            {"XPC_SERVICE_NAME": "com.mikerosoft.voice-type"},
            clear=True,
        ):
            self.assertTrue(self.module.restart_supervisor_active())

    def test_loaded_agent_does_not_make_a_manual_process_supervised(self):
        with mock.patch.dict(self.module.os.environ, {}, clear=True):
            with mock.patch.object(self.module.subprocess, "run") as run_mock:
                self.assertFalse(self.module.restart_supervisor_active())

        run_mock.assert_not_called()

    def test_other_launchd_service_does_not_own_this_process(self):
        with mock.patch.dict(
            self.module.os.environ,
            {"XPC_SERVICE_NAME": "com.example.other-service"},
            clear=True,
        ):
            self.assertFalse(self.module.restart_supervisor_active())

    def test_wake_and_display_events_have_independent_generations(self):
        initial_wake, initial_display = self.module.lifecycle_event_snapshot()

        self.module._note_system_wake(None)
        after_wake = self.module.lifecycle_event_snapshot()
        self.module._note_display_change(None)
        after_display = self.module.lifecycle_event_snapshot()

        self.assertEqual((initial_wake + 1, initial_display), after_wake)
        self.assertEqual((initial_wake + 1, initial_display + 1), after_display)


if __name__ == "__main__":
    unittest.main()
