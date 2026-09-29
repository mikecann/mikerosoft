#!/usr/bin/env python3
"""Toggle Filmora playback from anywhere on macOS with F16."""

from __future__ import annotations

import logging
import os
import signal
import subprocess
import sys
import threading
from dataclasses import dataclass
from typing import Any, Callable, Optional


HOTKEY = "<f16>"
LOG_FILE = os.path.expanduser("~/Library/Logs/filmora-hotkey.log")

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger(__name__)


@dataclass(frozen=True)
class ToggleResult:
    ok: bool
    message: str


class F16PressGuard:
    """Fire once per physical press, even when the keyboard repeats F16."""

    def __init__(self, activate: Callable[[], None]) -> None:
        self._activate = activate
        self._is_down = False

    def press(self, is_f16: bool) -> None:
        if not is_f16 or self._is_down:
            return
        self._is_down = True
        self._activate()

    def release(self, is_f16: bool) -> None:
        if is_f16:
            self._is_down = False


def find_play_pause_item(
    menu_bar: Any,
    get_children: Callable[[Any], list[Any]],
    get_title: Callable[[Any], Optional[str]],
) -> Any:
    for menu_bar_item in get_children(menu_bar):
        if get_title(menu_bar_item) != "View":
            continue
        for menu in get_children(menu_bar_item):
            for menu_item in get_children(menu):
                if get_title(menu_item) == "Play / Pause":
                    return menu_item
    return None


def find_filmora_pid() -> Optional[int]:
    try:
        result = subprocess.run(
            ["pgrep", "-x", "Wondershare Filmora Mac"],
            capture_output=True,
            text=True,
            timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None

    if result.returncode != 0:
        return None
    try:
        return int(result.stdout.splitlines()[0])
    except (IndexError, ValueError):
        return None


def press_filmora_play_pause(pid: int) -> bool:
    from ApplicationServices import (
        AXIsProcessTrusted,
        AXUIElementCopyAttributeValue,
        AXUIElementCreateApplication,
        AXUIElementPerformAction,
        kAXChildrenAttribute,
        kAXMenuBarAttribute,
        kAXPressAction,
        kAXTitleAttribute,
    )

    if not AXIsProcessTrusted():
        raise PermissionError("Accessibility permission has not been granted")

    def get_attribute(element: Any, attribute: str) -> Any:
        error, value = AXUIElementCopyAttributeValue(element, attribute, None)
        return value if error == 0 else None

    app = AXUIElementCreateApplication(pid)
    menu_bar = get_attribute(app, kAXMenuBarAttribute)
    if menu_bar is None:
        return False

    menu_item = find_play_pause_item(
        menu_bar,
        get_children=lambda element: get_attribute(element, kAXChildrenAttribute) or [],
        get_title=lambda element: get_attribute(element, kAXTitleAttribute),
    )
    if menu_item is None:
        return False

    return AXUIElementPerformAction(menu_item, kAXPressAction) == 0


def toggle_filmora_playback(
    find_pid: Callable[[], Optional[int]] = find_filmora_pid,
    press_play_pause: Callable[[int], bool] = press_filmora_play_pause,
) -> ToggleResult:
    pid = find_pid()
    if pid is None:
        return ToggleResult(False, "Filmora is not running")

    try:
        pressed = press_play_pause(pid)
    except PermissionError:
        return ToggleResult(
            False,
            "Accessibility permission is required for Filmora Hotkey",
        )
    except Exception as error:
        return ToggleResult(False, f"Filmora playback could not be toggled: {error}")

    if not pressed:
        return ToggleResult(False, "Filmora's Play / Pause menu command was not found")
    return ToggleResult(True, "Filmora playback toggled")


_toggle_lock = threading.Lock()


def on_hotkey() -> None:
    if not _toggle_lock.acquire(blocking=False):
        log.info("Ignoring F16 while the previous toggle is still running")
        return

    def toggle() -> None:
        try:
            result = toggle_filmora_playback()
            (log.info if result.ok else log.warning)(result.message)
        finally:
            _toggle_lock.release()

    threading.Thread(target=toggle, daemon=True, name="filmora-toggle").start()


def main() -> None:
    # Keep the optional runtime dependency out of module import so unit tests
    # can exercise the Filmora control logic before setup_mac.sh has run.
    from pynput import keyboard
    from ApplicationServices import AXIsProcessTrusted
    from Quartz import CGPreflightListenEventAccess

    log.info(
        "filmora-hotkey starting (hotkey: F16, accessibility: %s, input monitoring: %s)",
        AXIsProcessTrusted(),
        CGPreflightListenEventAccess(),
    )
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    press_guard = F16PressGuard(on_hotkey)
    with keyboard.Listener(
        on_press=lambda key: press_guard.press(key == keyboard.Key.f16),
        on_release=lambda key: press_guard.release(key == keyboard.Key.f16),
    ) as listener:
        log.info("Listening for F16")
        listener.join()


if __name__ == "__main__":
    main()
