import os
import pathlib
import subprocess
import tempfile
import unittest


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
WRAPPER = TOOLS_DIR / "launch-voice-type-mac.sh"


class MacLaunchWrapperTests(unittest.TestCase):
    def _runtime(self, tmpdir):
        install_dir = pathlib.Path(tmpdir) / "runtime"
        log_dir = pathlib.Path(tmpdir) / "logs"
        bin_dir = install_dir / ".venv" / "bin"
        bin_dir.mkdir(parents=True)
        log_dir.mkdir()
        launcher = bin_dir / "Voice Type"
        launcher.write_text(
            "#!/usr/bin/env bash\n"
            "printf '%s\\n' \"$*\" > \"$VOICE_TYPE_TEST_LAUNCH_FILE\"\n"
            "exit 0\n",
            encoding="utf-8",
        )
        launcher.chmod(0o755)
        (install_dir / "voice-type.py").write_text("# worker\n", encoding="utf-8")
        return install_dir, log_dir

    def test_missing_worker_is_a_permanent_non_retrying_error(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            install_dir, log_dir = self._runtime(tmpdir)
            (install_dir / "voice-type.py").unlink()
            env = os.environ.copy()
            env["VOICE_TYPE_INSTALL_DIR"] = str(install_dir)
            env["VOICE_TYPE_LOG_DIR"] = str(log_dir)

            result = subprocess.run(
                ["bash", str(WRAPPER)],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(0, result.returncode)
            self.assertIn("PERMANENT STARTUP ERROR", result.stderr)

    def test_rotates_launchd_log_then_executes_worker(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            install_dir, log_dir = self._runtime(tmpdir)
            launch_file = pathlib.Path(tmpdir) / "launch.txt"
            launchd_log = log_dir / "launchd.log"
            launchd_log.write_text("old line\n" * 20, encoding="utf-8")
            env = os.environ.copy()
            env["VOICE_TYPE_INSTALL_DIR"] = str(install_dir)
            env["VOICE_TYPE_LOG_DIR"] = str(log_dir)
            env["VOICE_TYPE_LAUNCHD_LOG_MAX_BYTES"] = "20"
            env["VOICE_TYPE_LAUNCHD_LOG_KEEP_LINES"] = "2"
            env["VOICE_TYPE_TEST_LAUNCH_FILE"] = str(launch_file)

            result = subprocess.run(
                ["bash", str(WRAPPER)],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual(
                str(install_dir / "voice-type.py"),
                launch_file.read_text(encoding="utf-8").strip(),
            )
            content = launchd_log.read_text(encoding="utf-8")
            self.assertIn("launchd log rotated", content)
            self.assertEqual(2, content.count("old line"))

    def test_uses_previously_approved_launcher_path_when_configured(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            install_dir, log_dir = self._runtime(tmpdir)
            launch_file = pathlib.Path(tmpdir) / "launch.txt"
            approved_launcher = pathlib.Path(tmpdir) / "approved Voice Type"
            approved_launcher.write_text(
                "#!/usr/bin/env bash\n"
                "printf 'approved:%s\\n' \"$*\" > \"$VOICE_TYPE_TEST_LAUNCH_FILE\"\n",
                encoding="utf-8",
            )
            approved_launcher.chmod(0o755)
            (install_dir / "trusted-launcher-path").write_text(
                f"{approved_launcher}\n",
                encoding="utf-8",
            )
            env = os.environ.copy()
            env["VOICE_TYPE_INSTALL_DIR"] = str(install_dir)
            env["VOICE_TYPE_LOG_DIR"] = str(log_dir)
            env["VOICE_TYPE_TEST_LAUNCH_FILE"] = str(launch_file)

            result = subprocess.run(
                ["bash", str(WRAPPER)],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual(
                f"approved:{install_dir / 'voice-type.py'}",
                launch_file.read_text(encoding="utf-8").strip(),
            )


if __name__ == "__main__":
    unittest.main()
