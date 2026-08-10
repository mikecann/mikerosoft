import os
import pathlib
import subprocess
import tempfile
import time
import unittest
import shutil


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
SCRIPT_PATH = TOOLS_DIR / "voice-type-mac.sh"


class MacRestartScriptTests(unittest.TestCase):
    def test_readiness_requires_the_native_hotkey_event_tap(self):
        script = SCRIPT_PATH.read_text(encoding="utf-8")
        self.assertIn("is_restart_ready", script)

    def test_restart_never_uses_broad_process_pattern_matching(self):
        script = SCRIPT_PATH.read_text(encoding="utf-8")
        self.assertNotIn('pkill -f "$APP"', script)
        self.assertNotIn('pgrep -f "$APP"', script)

    def _write_command(self, directory, name, body):
        command = pathlib.Path(directory) / name
        command.write_text(f"#!/usr/bin/env bash\n{body}", encoding="utf-8")
        command.chmod(0o755)
        return command

    def _prepare_runtime(self, tmpdir, *, ready=True):
        runtime = pathlib.Path(tmpdir) / "runtime"
        runtime.mkdir()
        shutil.copy2(SCRIPT_PATH, runtime / SCRIPT_PATH.name)
        (runtime / "voice-type.py").write_text("# test worker\n", encoding="utf-8")
        bin_dir = runtime / ".venv" / "bin"
        bin_dir.mkdir(parents=True)
        self._write_command(
            bin_dir,
            "Voice Type",
            "# Native launcher test double.\nexit 0\n",
        )
        self._write_command(
            bin_dir,
            "python3",
            f"exit {0 if ready else 1}\n",
        )
        return runtime

    def _run_script(self, tmpdir, *, ready=True):
        runtime = self._prepare_runtime(tmpdir, ready=ready)
        env = dict(os.environ)
        env["PATH"] = f"{tmpdir}:{env['PATH']}"
        env["VOICE_TYPE_INSTALL_DIR"] = str(runtime)
        env["VOICE_TYPE_LAUNCH_AGENT_PATH"] = str(
            pathlib.Path(tmpdir) / "com.mikerosoft.voice-type.plist"
        )
        env["VOICE_TYPE_READY_TIMEOUT_SECONDS"] = "0.05"
        env["VOICE_TYPE_READY_POLL_SECONDS"] = "0.01"
        return subprocess.run(
            ["bash", str(SCRIPT_PATH)],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )

    def _wait_for_lines(self, path, minimum=1):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            if path.exists():
                lines = path.read_text(encoding="utf-8").splitlines()
                if len(lines) >= minimum:
                    return lines
            time.sleep(0.01)
        return []

    def test_loaded_launch_agent_is_restarted_without_manual_process_race(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp_path = pathlib.Path(tmpdir)
            calls_path = tmp_path / "launchctl-calls.txt"
            self._write_command(
                tmpdir,
                "launchctl",
                f"printf '%s\\n' \"$*\" >> {calls_path!s}\n"
                "exit 0\n",
            )
            for command, body in {
                "pkill": "#!/usr/bin/env bash\nexit 0\n",
                "pgrep": "#!/usr/bin/env bash\nexit 1\n",
                "nohup": "#!/usr/bin/env bash\nexit 0\n",
            }.items():
                self._write_command(tmpdir, command, body)

            result = self._run_script(tmpdir)

            self.assertEqual(0, result.returncode, result.stderr)
            calls = calls_path.read_text(encoding="utf-8").splitlines()
            self.assertEqual(
                [
                    f"print gui/{os.getuid()}/com.mikerosoft.voice-type",
                    f"kickstart -k gui/{os.getuid()}/com.mikerosoft.voice-type",
                ],
                calls,
            )
            self.assertIn("Restarted via LaunchAgent", result.stdout)

    def test_kickstart_success_without_readiness_returns_failure(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            calls_path = pathlib.Path(tmpdir) / "launchctl-calls.txt"
            self._write_command(
                tmpdir,
                "launchctl",
                f"printf '%s\\n' \"$*\" >> {calls_path!s}\n"
                "exit 0\n",
            )
            self._write_command(tmpdir, "pkill", "exit 0\n")

            result = self._run_script(tmpdir, ready=False)

            self.assertNotEqual(0, result.returncode)
            self.assertIn("did not become ready", result.stdout)
            self.assertNotIn("Restarted via LaunchAgent", result.stdout)

    def test_missing_launch_agent_uses_manual_fallback(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp_path = pathlib.Path(tmpdir)
            calls_path = tmp_path / "fallback-calls.txt"
            self._write_command(tmpdir, "launchctl", "exit 1\n")
            self._write_command(
                tmpdir,
                "pkill",
                f"printf 'pkill %s\\n' \"$*\" >> {calls_path!s}\nexit 0\n",
            )
            self._write_command(tmpdir, "pgrep", "exit 1\n")
            self._write_command(
                tmpdir,
                "nohup",
                f"printf 'nohup %s\\n' \"$*\" >> {calls_path!s}\nexit 0\n",
            )

            result = self._run_script(tmpdir)

            self.assertEqual(0, result.returncode, result.stderr)
            calls = self._wait_for_lines(calls_path, minimum=1)
            self.assertTrue(any(line.startswith("nohup ") for line in calls), calls)
            self.assertIn("Launching Voice Type", result.stdout)

    def test_failed_kickstart_falls_back_instead_of_reporting_success(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp_path = pathlib.Path(tmpdir)
            calls_path = tmp_path / "fallback-calls.txt"
            self._write_command(
                tmpdir,
                "launchctl",
                f"printf 'launchctl %s\\n' \"$*\" >> {calls_path!s}\n"
                "if [[ \"$1\" == \"print\" ]]; then exit 0; fi\n"
                "exit 1\n",
            )
            self._write_command(
                tmpdir,
                "pkill",
                f"printf 'pkill %s\\n' \"$*\" >> {calls_path!s}\nexit 0\n",
            )
            self._write_command(tmpdir, "pgrep", "exit 1\n")
            self._write_command(
                tmpdir,
                "nohup",
                f"printf 'nohup %s\\n' \"$*\" >> {calls_path!s}\nexit 0\n",
            )

            result = self._run_script(tmpdir)

            self.assertEqual(0, result.returncode, result.stderr)
            calls = self._wait_for_lines(calls_path, minimum=4)
            self.assertTrue(any(line.startswith("nohup ") for line in calls), calls)
            self.assertIn("LaunchAgent restart failed", result.stdout)
            self.assertNotIn("Restarted via LaunchAgent", result.stdout)
            launchctl_calls = [
                line.removeprefix("launchctl ")
                for line in calls
                if line.startswith("launchctl ")
            ]
            self.assertIn(
                f"bootout gui/{os.getuid()}/com.mikerosoft.voice-type",
                launchctl_calls,
            )
            bootout_index = next(
                index for index, line in enumerate(calls)
                if "bootout" in line
            )
            nohup_index = next(
                index for index, line in enumerate(calls)
                if line.startswith("nohup ")
            )
            self.assertLess(bootout_index, nohup_index)


if __name__ == "__main__":
    unittest.main()
