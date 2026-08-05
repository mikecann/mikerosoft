from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("photo_backup", ROOT / "photo_backup.py")
assert SPEC and SPEC.loader
PHOTO_BACKUP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PHOTO_BACKUP)


class ExportCommandTests(unittest.TestCase):
    def test_export_is_incremental_and_preserves_originals_and_metadata(self) -> None:
        config = PHOTO_BACKUP.Config(
            volume=Path("/Volumes/CannMedia"),
            volume_uuid="expected-uuid",
            library=Path("/Volumes/CannMedia/PhotoBackup/Photos Library.photoslibrary"),
            archive=Path("/Volumes/CannMedia/PhotoArchive"),
            osxphotos="/opt/photo-backup/bin/osxphotos",
        )

        command = PHOTO_BACKUP.build_export_command(
            config,
            Path("/Volumes/CannMedia/PhotoArchive/.photo-backup/reports/export.json"),
        )

        self.assertEqual(command[0], config.osxphotos)
        self.assertIn("--update", command)
        self.assertIn("--sidecar", command)
        self.assertIn("XMP", command)
        self.assertIn("--export-aae", command)
        self.assertIn("--retry", command)
        self.assertNotIn("--cleanup", command)
        self.assertNotIn("--convert-to-jpeg", command)
        self.assertNotIn("--export-as-hardlink", command)


class AutomaticExportTests(unittest.TestCase):
    def config(self) -> object:
        return PHOTO_BACKUP.Config(
            volume=Path("/Volumes/CannMedia"),
            volume_uuid="expected-uuid",
            library=Path("/Volumes/CannMedia/PhotoBackup/Photos Library.photoslibrary"),
            archive=Path("/Volumes/CannMedia/PhotoArchive"),
            osxphotos="osxphotos",
        )

    def test_waits_successfully_while_originals_are_missing(self) -> None:
        config = self.config()
        with (
            mock.patch.object(PHOTO_BACKUP, "require_runtime"),
            mock.patch.object(PHOTO_BACKUP, "query_count", return_value=7) as query,
            mock.patch.object(PHOTO_BACKUP, "export_ready_library") as export,
        ):
            result = PHOTO_BACKUP.run_automatic_export(config)

        self.assertEqual(result, 0)
        query.assert_called_once_with(config, "--missing")
        export.assert_not_called()

    def test_exports_when_every_original_is_local(self) -> None:
        config = self.config()
        with (
            mock.patch.object(PHOTO_BACKUP, "require_runtime"),
            mock.patch.object(PHOTO_BACKUP, "query_count", side_effect=[0, 100]) as query,
            mock.patch.object(
                PHOTO_BACKUP, "export_ready_library", return_value=0
            ) as export,
        ):
            result = PHOTO_BACKUP.run_automatic_export(config)

        self.assertEqual(result, 0)
        self.assertEqual(
            query.call_args_list,
            [mock.call(config, "--missing"), mock.call(config)],
        )
        export.assert_called_once_with(config, 100, quiet=True)

    def test_auto_is_a_supported_command(self) -> None:
        args = PHOTO_BACKUP.build_parser().parse_args(["auto"])

        self.assertEqual(args.command, "auto")


class AutomationInstallerTests(unittest.TestCase):
    def test_launchagent_runs_at_login_and_every_six_hours(self) -> None:
        installer = (ROOT / "install-automation.sh").read_text()

        self.assertIn("<key>RunAtLoad</key>", installer)
        self.assertIn("<key>StartInterval</key>", installer)
        self.assertIn("<integer>21600</integer>", installer)
        self.assertIn("launchctl bootstrap", installer)
        self.assertIn("Application Support/photo-backup/source/photo-backup", installer)
        self.assertNotIn("<key>KeepAlive</key>", installer)
        self.assertNotIn("launchctl kickstart", installer)
        self.assertNotIn("<key>ThrottleInterval</key>", installer)


class LayoutValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.volume = Path(self.temp_dir.name) / "CannMedia"
        self.volume.mkdir()
        self.library = self.volume / "PhotoBackup" / "Photos Library.photoslibrary"
        self.library.mkdir(parents=True)
        self.archive = self.volume / "PhotoArchive"

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def config(self) -> object:
        return PHOTO_BACKUP.Config(
            volume=self.volume,
            volume_uuid="expected-uuid",
            library=self.library,
            archive=self.archive,
            osxphotos="osxphotos",
        )

    def test_accepts_expected_apfs_volume_and_separate_paths(self) -> None:
        PHOTO_BACKUP.validate_layout(
            self.config(),
            PHOTO_BACKUP.VolumeInfo(
                uuid="expected-uuid",
                filesystem="APFS",
                mount_point=self.volume,
            ),
        )

    def test_rejects_wrong_physical_volume_identity(self) -> None:
        with self.assertRaisesRegex(PHOTO_BACKUP.PreflightError, "identity"):
            PHOTO_BACKUP.validate_layout(
                self.config(),
                PHOTO_BACKUP.VolumeInfo(
                    uuid="different-uuid",
                    filesystem="APFS",
                    mount_point=self.volume,
                ),
            )

    def test_rejects_non_apfs_volume(self) -> None:
        with self.assertRaisesRegex(PHOTO_BACKUP.PreflightError, "APFS"):
            PHOTO_BACKUP.validate_layout(
                self.config(),
                PHOTO_BACKUP.VolumeInfo(
                    uuid="expected-uuid",
                    filesystem="ExFAT",
                    mount_point=self.volume,
                ),
            )

    def test_rejects_archive_inside_managed_photos_library(self) -> None:
        config = self.config()
        config.archive = self.library / "NetworkExport"

        with self.assertRaisesRegex(PHOTO_BACKUP.PreflightError, "inside"):
            PHOTO_BACKUP.validate_layout(
                config,
                PHOTO_BACKUP.VolumeInfo(
                    uuid="expected-uuid",
                    filesystem="APFS",
                    mount_point=self.volume,
                ),
            )

    def test_rejects_library_or_archive_outside_configured_volume(self) -> None:
        config = self.config()
        config.archive = Path(self.temp_dir.name) / "SomewhereElse"

        with self.assertRaisesRegex(PHOTO_BACKUP.PreflightError, "configured volume"):
            PHOTO_BACKUP.validate_layout(
                config,
                PHOTO_BACKUP.VolumeInfo(
                    uuid="expected-uuid",
                    filesystem="APFS",
                    mount_point=self.volume,
                ),
            )


class CountParsingTests(unittest.TestCase):
    def test_parses_sanitized_osxphotos_count(self) -> None:
        self.assertEqual(PHOTO_BACKUP.parse_count("  12345\n"), 12345)

    def test_rejects_unexpected_count_output(self) -> None:
        with self.assertRaisesRegex(ValueError, "count"):
            PHOTO_BACKUP.parse_count("IMG_1234.JPG")

    def test_query_error_does_not_expose_photo_filename(self) -> None:
        config = PHOTO_BACKUP.Config(
            volume=Path("/Volumes/CannMedia"),
            volume_uuid="expected-uuid",
            library=Path("/Volumes/CannMedia/PhotoBackup/Photos Library.photoslibrary"),
            archive=Path("/Volumes/CannMedia/PhotoArchive"),
            osxphotos="osxphotos",
        )
        failed = subprocess.CompletedProcess(
            args=["osxphotos"],
            returncode=1,
            stdout="",
            stderr="could not read IMG_PRIVATE_1234.JPG",
        )

        with mock.patch.object(PHOTO_BACKUP.subprocess, "run", return_value=failed):
            with self.assertRaises(PHOTO_BACKUP.PreflightError) as context:
                PHOTO_BACKUP.query_count(config)

        self.assertNotIn("IMG_PRIVATE_1234.JPG", str(context.exception))

    def test_query_timeout_is_reported_without_private_details(self) -> None:
        config = PHOTO_BACKUP.Config(
            volume=Path("/Volumes/CannMedia"),
            volume_uuid="expected-uuid",
            library=Path("/Volumes/CannMedia/PhotoBackup/Photos Library.photoslibrary"),
            archive=Path("/Volumes/CannMedia/PhotoArchive"),
            osxphotos="osxphotos",
        )

        with mock.patch.object(
            PHOTO_BACKUP.subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired(["osxphotos"], 1800),
        ):
            with self.assertRaisesRegex(PHOTO_BACKUP.PreflightError, "timed out"):
                PHOTO_BACKUP.query_count(config)


class LauncherTests(unittest.TestCase):
    def test_isolates_osxphotos_config_from_existing_user_dotfiles(self) -> None:
        launcher = (ROOT / "photo-backup").read_text()

        self.assertIn("XDG_CONFIG_HOME", launcher)
        self.assertIn("XDG_DATA_HOME", launcher)
        self.assertIn("XDG_CACHE_HOME", launcher)

    def test_installed_source_launcher_finds_python_source(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            home = Path(temp_dir)
            source = home / "Library/Application Support/photo-backup/source"
            venv_bin = home / "Library/Application Support/photo-backup/venv/bin"
            source.mkdir(parents=True)
            venv_bin.mkdir(parents=True)

            (source / "photo_backup.py").write_text(
                (ROOT / "photo_backup.py").read_text()
            )
            (source / "photo-backup").write_text((ROOT / "photo-backup").read_text())
            (source / "photo-backup").chmod(0o755)
            (venv_bin / "python").symlink_to(sys.executable)
            launcher = source / "photo-backup"

            result = subprocess.run(
                [launcher, "--help"],
                env={**os.environ, "HOME": str(home)},
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Manage and verify Bruce's Apple Photos backup", result.stdout)


class SetupContractTests(unittest.TestCase):
    def test_setup_keeps_the_script_private_to_bruce(self) -> None:
        setup = (ROOT / "setup_mac.sh").read_text()

        self.assertIn("Library/Application Support/photo-backup", setup)
        self.assertNotIn(".local/bin", setup)
        self.assertNotIn("ln -s", setup)


if __name__ == "__main__":
    unittest.main()
