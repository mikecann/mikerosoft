#!/usr/bin/env python3
"""Verify and export Bruce's Apple Photos library without exposing filenames."""

from __future__ import annotations

import argparse
import os
import plistlib
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Optional, Sequence


DEFAULT_VOLUME = Path("/Volumes/CannMedia")
DEFAULT_VOLUME_UUID = "5CCB1D81-5A98-4C4A-9E2C-3E10B23F1B46"
DEFAULT_LIBRARY = DEFAULT_VOLUME / "PhotoBackup" / "Photos Library.photoslibrary"
DEFAULT_ARCHIVE = DEFAULT_VOLUME / "PhotoArchive"
# A near-complete external Photos library can take well over 30 minutes to
# load and evaluate. Keep the query bounded, but leave enough room for a real
# readiness result before the six-hour LaunchAgent schedule runs again.
QUERY_TIMEOUT_SECONDS = 2 * 60 * 60


class PreflightError(RuntimeError):
    """Raised when the configured backup target is not safe to use."""


class Config:
    def __init__(
        self,
        *,
        volume: Path,
        volume_uuid: str,
        library: Path,
        archive: Path,
        osxphotos: str,
    ) -> None:
        self.volume = volume
        self.volume_uuid = volume_uuid
        self.library = library
        self.archive = archive
        self.osxphotos = osxphotos


class VolumeInfo:
    def __init__(self, *, uuid: str, filesystem: str, mount_point: Path) -> None:
        self.uuid = uuid
        self.filesystem = filesystem
        self.mount_point = mount_point


def default_osxphotos_path() -> str:
    override = os.environ.get("PHOTO_BACKUP_OSXPHOTOS")
    if override:
        return override

    installed = (
        Path.home()
        / "Library"
        / "Application Support"
        / "photo-backup"
        / "venv"
        / "bin"
        / "osxphotos"
    )
    if installed.is_file():
        return str(installed)

    return shutil.which("osxphotos") or "osxphotos"


def config_from_environment() -> Config:
    return Config(
        volume=Path(os.environ.get("PHOTO_BACKUP_VOLUME", str(DEFAULT_VOLUME))),
        volume_uuid=os.environ.get(
            "PHOTO_BACKUP_VOLUME_UUID", DEFAULT_VOLUME_UUID
        ),
        library=Path(os.environ.get("PHOTO_BACKUP_LIBRARY", str(DEFAULT_LIBRARY))),
        archive=Path(os.environ.get("PHOTO_BACKUP_ARCHIVE", str(DEFAULT_ARCHIVE))),
        osxphotos=default_osxphotos_path(),
    )


def _resolved(path: Path) -> Path:
    return path.expanduser().resolve(strict=False)


def _is_within(path: Path, parent: Path) -> bool:
    resolved_path = _resolved(path)
    resolved_parent = _resolved(parent)
    try:
        resolved_path.relative_to(resolved_parent)
        return True
    except ValueError:
        return False


def load_volume_info(volume: Path) -> VolumeInfo:
    completed = subprocess.run(
        ["diskutil", "info", "-plist", str(volume)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        raise PreflightError(f"Could not inspect configured volume: {detail}")

    try:
        payload = plistlib.loads(completed.stdout)
    except Exception as exc:
        raise PreflightError("diskutil returned unreadable volume information") from exc

    volume_uuid = str(payload.get("VolumeUUID") or "")
    filesystem = str(
        payload.get("FilesystemType")
        or payload.get("FileSystemPersonality")
        or payload.get("FilesystemName")
        or ""
    )
    mount_point = Path(str(payload.get("MountPoint") or volume))
    return VolumeInfo(
        uuid=volume_uuid,
        filesystem=filesystem,
        mount_point=mount_point,
    )


def validate_layout(config: Config, volume_info: VolumeInfo) -> None:
    if not config.volume.is_dir():
        raise PreflightError(f"Configured volume is not mounted: {config.volume}")

    if volume_info.uuid.casefold() != config.volume_uuid.casefold():
        raise PreflightError(
            "Configured path is mounted from the wrong physical volume identity"
        )

    if "apfs" not in volume_info.filesystem.casefold():
        raise PreflightError("Photo backup requires an APFS destination")

    if _resolved(volume_info.mount_point) != _resolved(config.volume):
        raise PreflightError("diskutil mount point does not match the configured volume")

    if not _is_within(config.library, config.volume):
        raise PreflightError("Photos library is outside the configured volume")

    if not _is_within(config.archive, config.volume):
        raise PreflightError("Photo archive is outside the configured volume")

    if _is_within(config.archive, config.library):
        raise PreflightError("Photo archive cannot be inside the managed Photos library")

    if _is_within(config.library, config.archive):
        raise PreflightError("Managed Photos library cannot be inside the photo archive")

    if config.library.suffix.casefold() != ".photoslibrary":
        raise PreflightError("Configured library must be a .photoslibrary package")


def parse_count(output: str) -> int:
    value = output.strip()
    if not value.isdigit():
        raise ValueError("osxphotos returned an unexpected count")
    return int(value)


def query_count(config: Config, *query_options: str) -> int:
    command = [
        config.osxphotos,
        "query",
        "--library",
        str(config.library),
        "--count",
        *query_options,
    ]
    try:
        completed = subprocess.run(
            command,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=QUERY_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as exc:
        raise PreflightError(
            "Could not query Photos library (osxphotos timed out)"
        ) from exc
    if completed.returncode != 0:
        # osxphotos errors can contain private filenames. Status output is
        # aggregate-only, so report the process result without echoing stderr.
        raise PreflightError(
            f"Could not query Photos library (osxphotos exit {completed.returncode})"
        )
    return parse_count(completed.stdout)


def build_export_command(config: Config, report_path: Path) -> list[str]:
    # A normal osxphotos copy between paths on the same APFS volume is a
    # copy-on-write clone. Do not use hardlinks: clones are independent files.
    return [
        config.osxphotos,
        "export",
        str(config.archive),
        "--library",
        str(config.library),
        "--update",
        "--update-errors",
        "--directory",
        "{created.year}/{created.mm}",
        "--sidecar",
        "XMP",
        "--export-aae",
        "--retry",
        "3",
        "--report",
        str(report_path),
    ]


def require_runtime(config: Config) -> VolumeInfo:
    volume_info = load_volume_info(config.volume)
    validate_layout(config, volume_info)

    if not config.library.is_dir():
        raise PreflightError(f"Photos library is missing: {config.library}")

    executable = shutil.which(config.osxphotos)
    if not executable and not Path(config.osxphotos).is_file():
        raise PreflightError(
            "osxphotos is not installed; run scripts/bruce/photo-backup/setup_mac.sh"
        )
    return volume_info


def photos_is_running() -> bool:
    return subprocess.run(
        ["pgrep", "-x", "Photos"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0


def backblaze_worker_count() -> int:
    completed = subprocess.run(
        ["pgrep", "-if", "bztransmit"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if completed.returncode != 0:
        return 0
    return len([line for line in completed.stdout.splitlines() if line.strip()])


def print_status(config: Config) -> int:
    require_runtime(config)
    usage = shutil.disk_usage(config.volume)
    total = query_count(config)
    cloud = query_count(config, "--cloudasset")
    missing = query_count(config, "--missing")
    videos = query_count(config, "--only-movies")

    print("Photo Backup Status")
    print(f"  Volume: {config.volume} (APFS identity verified)")
    print(f"  Free: {usage.free / (1024**4):.2f} TiB")
    print(f"  Library: {config.library}")
    print(f"  Archive: {config.archive}")
    print(f"  Assets: {total}")
    print(f"  Videos: {videos}")
    print(f"  iCloud assets: {cloud}")
    print(f"  Originals missing locally: {missing}")
    print(f"  Photos app: {'running' if photos_is_running() else 'stopped'}")
    workers = backblaze_worker_count()
    print(
        "  Backblaze transfer workers: "
        f"{workers} ({'active' if workers else 'paused or idle'})"
    )

    if total == 0:
        print("  State: WAITING_FOR_ICLOUD_LIBRARY")
        return 2
    if missing > 0:
        print("  State: DOWNLOADING_ORIGINALS")
        return 2

    print("  State: ORIGINALS_READY")
    return 0


def export_ready_library(
    config: Config, total: Optional[int], *, quiet: bool = False
) -> int:
    reports = config.archive / ".photo-backup" / "reports"
    reports.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%dT%H%M%S")
    report_path = reports / f"export-{timestamp}.json"
    command = build_export_command(config, report_path)

    if total is None:
        print("Exporting Photos assets to the APFS clone archive...")
    else:
        print(f"Exporting {total} Photos assets to the APFS clone archive...")
    completed = subprocess.run(
        command,
        check=False,
        stdout=subprocess.DEVNULL if quiet else None,
        stderr=subprocess.DEVNULL if quiet else None,
    )
    if completed.returncode != 0:
        raise PreflightError(
            f"osxphotos export failed with exit code {completed.returncode}"
        )

    print(f"Export report: {report_path}")
    print("State: EXPORT_COMPLETE")
    return 0


def run_export(config: Config) -> int:
    require_runtime(config)
    total = query_count(config)
    missing = query_count(config, "--missing")
    if total == 0:
        raise PreflightError("Photos library contains no assets yet")
    if missing:
        raise PreflightError(
            f"Refusing archive export while {missing} originals are missing locally"
        )

    return export_ready_library(config, total)


def run_automatic_export(config: Config) -> int:
    """Wait harmlessly for iCloud, then incrementally update the archive."""
    require_runtime(config)
    started = datetime.now().astimezone().isoformat(timespec="seconds")
    print(f"Automatic photo backup check: {started}", flush=True)
    # During the initial iCloud ingest, the only decision needed is whether
    # any original remains missing. Check that first so the scheduled job can
    # avoid an unnecessary second full database scan while it is still waiting.
    missing = query_count(config, "--missing")
    print(f"  Originals missing locally: {missing}", flush=True)
    if missing:
        print("  State: WAITING_FOR_ORIGINALS", flush=True)
        return 0

    print("  State: ORIGINALS_READY", flush=True)
    # Automated logs stay aggregate-only. The detailed export report remains
    # private inside the archive instead of streaming filenames to launchd.
    # Do not repeat a second multi-hour catalogue scan after the missing check
    # has already proved that every original is local.
    return export_ready_library(config, None, quiet=True)


def print_paths(config: Config) -> int:
    volume_info = load_volume_info(config.volume)
    validate_layout(config, volume_info)
    print(f"Volume: {config.volume}")
    print(f"Library: {config.library}")
    print(f"Archive: {config.archive}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Manage and verify Bruce's Apple Photos backup"
    )
    parser.add_argument(
        "command",
        choices=("paths", "status", "export", "auto"),
        help="paths validates the target; status reports aggregate sync state; export updates the APFS clone archive; auto waits for originals and then exports",
    )
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    config = config_from_environment()
    try:
        if args.command == "paths":
            return print_paths(config)
        if args.command == "status":
            return print_status(config)
        if args.command == "export":
            return run_export(config)
        if args.command == "auto":
            return run_automatic_export(config)
    except (PreflightError, OSError, ValueError) as exc:
        print(f"photo-backup: {exc}", file=sys.stderr)
        return 1
    return 64


if __name__ == "__main__":
    raise SystemExit(main())
