import importlib.util
import os
import pathlib
import sys
import tempfile
import unittest


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOLS_DIR / "process_relaunch.py"


def load_module():
    spec = importlib.util.spec_from_file_location("process_relaunch", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ProcessRelaunchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_current_process_exits_after_relauncher_is_spawned(self):
        events = []

        self.module.restart_current_process(
            managed_by_supervisor=False,
            spawn=lambda: events.append("spawned"),
            exit_process=lambda code: events.append(("exited", code)),
        )

        self.assertEqual(
            ["spawned", ("exited", self.module.RESTART_EXIT_CODE)],
            events,
        )

    def test_managed_process_exits_and_lets_supervisor_restart_it(self):
        events = []

        self.module.restart_current_process(
            managed_by_supervisor=True,
            spawn=lambda: events.append("spawned"),
            exit_process=lambda code: events.append(("exited", code)),
        )

        self.assertEqual(
            [("exited", self.module.RESTART_EXIT_CODE)],
            events,
        )

    def test_spawn_failure_keeps_current_process_alive_for_retry(self):
        events = []

        def fail_spawn():
            raise RuntimeError("launcher unavailable")

        restarted = self.module.restart_current_process(
            managed_by_supervisor=False,
            spawn=fail_spawn,
            exit_process=lambda code: events.append(("exited", code)),
            on_error=lambda error: events.append(("error", str(error))),
        )

        self.assertFalse(restarted)
        self.assertEqual([("error", "launcher unavailable")], events)

    def test_missing_relauncher_file_is_rejected_before_process_exit(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            missing = os.path.join(tmpdir, "missing-restart-script")

            with self.assertRaisesRegex(FileNotFoundError, "missing-restart-script"):
                self.module.validate_relauncher_files(
                    required_paths=[missing],
                )

    def test_non_executable_launcher_is_rejected_before_process_exit(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            launcher = pathlib.Path(tmpdir) / "Voice Type"
            launcher.write_text("launcher", encoding="utf-8")
            launcher.chmod(0o644)

            with self.assertRaisesRegex(PermissionError, "Voice Type"):
                self.module.validate_relauncher_files(
                    required_paths=[str(launcher)],
                    executable_paths=[str(launcher)],
                )

    def test_valid_relauncher_files_pass_validation(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            script = pathlib.Path(tmpdir) / "restart.sh"
            launcher = pathlib.Path(tmpdir) / "Voice Type"
            script.write_text("#!/bin/sh\n", encoding="utf-8")
            launcher.write_text("#!/bin/sh\n", encoding="utf-8")
            launcher.chmod(0o755)

            self.module.validate_relauncher_files(
                required_paths=[str(script), str(launcher)],
                executable_paths=[str(launcher)],
            )

    def test_worker_command_must_end_with_exact_app_path(self):
        launcher = "/somewhere/Voice Type"
        app = "/Users/mike/Library/Application Support/Voice Type/voice-type.py"

        self.assertTrue(
            self.module.command_targets_worker(
                launcher + " " + app,
                launcher_path=launcher,
                app_path=app,
            )
        )
        self.assertFalse(
            self.module.command_targets_worker(
                "zsh -c tail " + app,
                launcher_path=launcher,
                app_path=app,
            )
        )
        self.assertFalse(
            self.module.command_targets_worker(
                "/somewhere/Voice Type /tmp/voice-type.py",
                launcher_path=launcher,
                app_path=app,
            )
        )


if __name__ == "__main__":
    unittest.main()
