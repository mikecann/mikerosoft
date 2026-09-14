#!/usr/bin/env python3
"""Install an ordinary launchd timer. No Codex heartbeat or model polling."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import sys

from bookmarks import DEFAULT_STATE, CaptureError, Store, XApi, config_read

LABEL = "com.mikerosoft.x-bookmarks"


def launchagent(state, config, script, python, log):
    return {"Label": LABEL,
            "ProgramArguments": [str(python), str(script), "--state-dir", str(state), "--config", str(config), "tick"],
            "StartInterval": 60, "RunAtLoad": True,
            "StandardOutPath": str(log), "StandardErrorPath": str(log),
            "EnvironmentVariables": {"PATH": f"{Path(python).parent}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                                     "PYTHONUNBUFFERED": "1"}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", type=Path, default=DEFAULT_STATE)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--output", type=Path, help="render a plist only; do not install or start it")
    parser.add_argument("--uninstall", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)
    root = args.state_dir.expanduser().resolve()
    config_path = (args.config or root / "config.json").expanduser().resolve()
    destination = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
    service = f"gui/{os.getuid()}/{LABEL}"
    if args.uninstall:
        subprocess.run(["launchctl", "bootout", service], capture_output=True)
        destination.unlink(missing_ok=True)
        print("Stopped x-bookmarks. Private state and deduplication history retained.")
        return
    config = config_read(config_path)
    script = Path(__file__).resolve().with_name("bookmarks.py")
    if not args.output:
        if sys.platform != "darwin":
            raise CaptureError("The service installer requires macOS")
        XApi(config)  # Local checks only. Never make a paid request during installation.
        store = Store(root)
        try:
            if not store.get("baseline"):
                raise CaptureError("Run one successful poll to establish a baseline before installing")
        finally:
            store.close()
        if config.get("enable_experimental_codex_delivery"):
            binary = Path(config["codex_binary"]).expanduser()
            if not binary.is_absolute() or not os.access(binary, os.X_OK):
                raise CaptureError("Set codex_binary to an absolute executable path for launchd")
            subprocess.run([sys.executable, str(script), "--state-dir", str(root),
                            "--config", str(config_path), "doctor"], check=True)
    log = Path.home() / "Library/Logs/x-bookmarks.log"
    output = args.output or destination
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(plistlib.dumps(launchagent(root, config_path, script, Path(sys.executable).resolve(), log)))
    if args.output:
        print(f"Rendered only: {output}")
        return
    log.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["launchctl", "bootout", service], capture_output=True)
    subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(destination)], check=True)
    print(f"Installed {LABEL}. Log: {log}")


if __name__ == "__main__":
    try:
        main()
    except (CaptureError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(str(error) if isinstance(error, CaptureError) else f"Service setup failed: {type(error).__name__}", file=sys.stderr)
        sys.exit(1)
