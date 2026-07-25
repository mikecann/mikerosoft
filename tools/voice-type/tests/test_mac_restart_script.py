import os
import pathlib
import subprocess
import tempfile
import time
import unittest


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
SCRIPT_PATH = TOOLS_DIR / "voice-type-mac.sh"


class MacRestartScriptTests(unittest.TestCase):
    def _write_command(self, directory, name, body):
        command = pathlib.Path(directory) / name
        command.write_text(f"#!/usr/bin/env bash\n{body}", encoding="utf-8")
        command.chmod(0o755)
        return command

    def _run_script(self, tmpdir):
        env = dict(os.environ)
        env["PATH"] = f"{tmpdir}:{env['PATH']}"
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
            calls = self._wait_for_lines(calls_path, minimum=3)
            self.assertTrue(any(line.startswith("nohup ") for line in calls), calls)
            self.assertIn("Launching voice-type", result.stdout)

    def test_failed_kickstart_falls_back_instead_of_reporting_success(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp_path = pathlib.Path(tmpdir)
            calls_path = tmp_path / "fallback-calls.txt"
            self._write_command(
                tmpdir,
                "launchctl",
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
            calls = self._wait_for_lines(calls_path, minimum=5)
            self.assertTrue(any(line.startswith("nohup ") for line in calls), calls)
            self.assertIn("LaunchAgent restart failed", result.stdout)
            self.assertNotIn("Restarted via LaunchAgent", result.stdout)


if __name__ == "__main__":
    unittest.main()
