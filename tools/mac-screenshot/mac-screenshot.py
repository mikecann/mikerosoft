#!/usr/bin/env python3
"""mac-screenshot: Global hotkey screenshot daemon for macOS.

Press F11 to:
  1. Enter selection-capture mode (crosshair cursor)
  2. Save the region to ~/Desktop/Screenshots with a timestamp name
  3. Copy the image to the clipboard
  4. Open in Preview for quick annotation

Edit HOTKEY or SAVE_DIR below to customise.
"""

import logging
import os
import signal
import subprocess
import sys
import threading
from datetime import datetime

from pynput import keyboard

HOTKEY = "<f11>"
SAVE_DIR = os.path.expanduser("~/Desktop/Screenshots")
LOG_FILE = os.path.expanduser("~/Library/Logs/mac-screenshot.log")

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)


def get_active_app() -> str:
    script = (
        "tell application \"System Events\" to "
        "name of first application process whose frontmost is true"
    )
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True,
            text=True,
            timeout=2,
        )
    except subprocess.TimeoutExpired:
        log.warning("Active app lookup timed out")
        return ""

    if result.returncode != 0:
        log.warning("Active app lookup failed: %s", result.stderr.strip())
        return ""

    return result.stdout.strip()


def sanitize(name: str) -> str:
    return "".join(c for c in name if c not in r'/:*?"<>|\\')


def build_filepath() -> str:
    os.makedirs(SAVE_DIR, exist_ok=True)
    timestamp = datetime.now().strftime("%Y-%m-%d at %H.%M.%S")
    app = sanitize(get_active_app())
    name = (
        f"Screenshot {timestamp} - {app}.png" if app
        else f"Screenshot {timestamp}.png"
    )
    return os.path.join(SAVE_DIR, name)


def copy_to_clipboard(filepath: str) -> None:
    # «class PNGf» is the AppleScript raw type code for PNG data
    script = f'set the clipboard to (read (POSIX file "{filepath}") as \u00abclass PNGf\u00bb)'
    result = subprocess.run(["osascript", "-e", script], capture_output=True)
    if result.returncode != 0:
        log.warning("Clipboard copy failed: %s", result.stderr.decode())


def notify(message: str) -> None:
    script = f'display notification "{message}" with title "mac-screenshot"'
    subprocess.run(["osascript", "-e", script], capture_output=True)


def take_screenshot() -> None:
    filepath = build_filepath()
    log.info("Starting capture -> %s", filepath)

    result = subprocess.run(["screencapture", "-i", filepath])

    if result.returncode != 0 or not os.path.exists(filepath):
        log.info("Capture cancelled")
        return

    log.info("Saved %s", os.path.basename(filepath))
    copy_to_clipboard(filepath)
    subprocess.Popen(["open", "-a", "Preview", filepath])
    notify(f"Saved {os.path.basename(filepath)}")


def on_hotkey() -> None:
    threading.Thread(target=take_screenshot, daemon=True).start()


def main() -> None:
    log.info("mac-screenshot starting (hotkey: %s, save dir: %s)", HOTKEY, SAVE_DIR)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    with keyboard.GlobalHotKeys({HOTKEY: on_hotkey}) as listener:
        log.info("Listening for hotkey...")
        listener.join()


if __name__ == "__main__":
    main()
