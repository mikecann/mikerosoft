import os
import pathlib
import plistlib
import subprocess
import tempfile
import unittest


VOICE_TYPE_DIR = pathlib.Path(__file__).resolve().parents[1]
INSTALLER = VOICE_TYPE_DIR / "install-spotlight-app.sh"


class SpotlightAppInstallerTests(unittest.TestCase):
    def test_setup_supports_the_uv_managed_python_used_on_this_mac(self):
        setup = (VOICE_TYPE_DIR / "setup_mac.sh").read_text()
        self.assertIn("uv python find 3.12", setup)

    def test_setup_preserves_the_native_launchers_tcc_identity(self):
        setup = (VOICE_TYPE_DIR / "setup_mac.sh").read_text()
        self.assertIn("Preserving existing native launcher identity", setup)
        self.assertIn("VOICE_TYPE_TRUSTED_LAUNCHER", setup)
        self.assertIn("trusted-launcher-path", setup)
        self.assertIn("VOICE_TYPE_REBUILD_LAUNCHER", setup)
        self.assertIn('designated => identifier "com.mikerosoft.voice-type"', setup)

    def test_settings_launcher_recovers_from_a_stale_control_socket(self):
        launcher = (VOICE_TYPE_DIR / "open-settings-mac.sh").read_text()
        self.assertIn("restart_after_failed_request", launcher)
        self.assertIn('rm -f "$SOCKET_PATH"', launcher)

    def test_installs_application_bundle_that_opens_settings(self):
        with tempfile.TemporaryDirectory() as tmp:
            app_dir = pathlib.Path(tmp) / "Voice Type.app"
            env = os.environ.copy()
            env["VOICE_TYPE_APP_DIR"] = str(app_dir)

            subprocess.run(["bash", str(INSTALLER)], env=env, check=True)

            executable = app_dir / "Contents" / "MacOS" / "voice-type-settings"
            plist_path = app_dir / "Contents" / "Info.plist"
            self.assertTrue(os.access(executable, os.X_OK))
            self.assertIn(str(VOICE_TYPE_DIR / "open-settings-mac.sh"), executable.read_text())

            with plist_path.open("rb") as stream:
                plist = plistlib.load(stream)
            self.assertEqual("com.mikerosoft.voice-type", plist["CFBundleIdentifier"])
            self.assertEqual("Voice Type", plist["CFBundleDisplayName"])
            self.assertEqual("voice-type-settings", plist["CFBundleExecutable"])


if __name__ == "__main__":
    unittest.main()
