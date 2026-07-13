import os
from typing import Optional

from taskbar_model import WindowRecord


def _window_value(window, key, default=None):
    return window.get(key, default)


def _bounds_value(bounds, key, default=0):
    if bounds is None:
        return default
    return bounds.get(key, bounds.get(key.lower(), default))


def current_pid() -> int:
    return os.getpid()


def get_frontmost_pid() -> Optional[int]:
    from AppKit import NSWorkspace

    app = NSWorkspace.sharedWorkspace().frontmostApplication()
    if app is None:
        return None
    return int(app.processIdentifier())


def activate_pid(pid: int) -> bool:
    from AppKit import (
        NSApplicationActivateAllWindows,
        NSApplicationActivateIgnoringOtherApps,
        NSRunningApplication,
    )

    app = NSRunningApplication.runningApplicationWithProcessIdentifier_(int(pid))
    if app is None:
        return False

    options = NSApplicationActivateIgnoringOtherApps | NSApplicationActivateAllWindows
    return bool(app.activateWithOptions_(options))


def collect_window_records() -> list[WindowRecord]:
    import Quartz
    from AppKit import NSRunningApplication

    options = Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements
    raw_windows = Quartz.CGWindowListCopyWindowInfo(options, Quartz.kCGNullWindowID) or []
    records = []

    for window in raw_windows:
        pid = int(_window_value(window, Quartz.kCGWindowOwnerPID, 0) or 0)
        app = NSRunningApplication.runningApplicationWithProcessIdentifier_(pid)
        bundle_url = app.bundleURL() if app else None
        bounds = _window_value(window, Quartz.kCGWindowBounds, {}) or {}

        records.append(
            WindowRecord(
                owner=str(_window_value(window, Quartz.kCGWindowOwnerName, "") or ""),
                title=str(_window_value(window, Quartz.kCGWindowName, "") or ""),
                pid=pid,
                window_id=int(_window_value(window, Quartz.kCGWindowNumber, 0) or 0),
                layer=int(_window_value(window, Quartz.kCGWindowLayer, 0) or 0),
                is_on_screen=bool(_window_value(window, Quartz.kCGWindowIsOnscreen, True)),
                bounds={
                    "X": _bounds_value(bounds, "X"),
                    "Y": _bounds_value(bounds, "Y"),
                    "Width": _bounds_value(bounds, "Width"),
                    "Height": _bounds_value(bounds, "Height"),
                },
                bundle_id=str(app.bundleIdentifier() or "") if app else "",
                app_path=str(bundle_url.path() or "") if bundle_url else "",
            )
        )

    return records
