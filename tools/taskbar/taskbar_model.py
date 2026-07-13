from dataclasses import dataclass
from typing import Any, Optional


MIN_WINDOW_WIDTH = 64
MIN_WINDOW_HEIGHT = 40

IGNORED_OWNERS = {
    "Control Center",
    "Dock",
    "Notification Center",
    "Spotlight",
    "SystemUIServer",
    "Window Server",
    "loginwindow",
}


@dataclass(frozen=True)
class WindowRecord:
    owner: str
    title: str
    pid: int
    window_id: int
    layer: int
    is_on_screen: bool
    bounds: dict[str, Any]
    bundle_id: str = ""
    app_path: str = ""

    @property
    def width(self) -> float:
        return float(self.bounds.get("Width", self.bounds.get("width", 0)) or 0)

    @property
    def height(self) -> float:
        return float(self.bounds.get("Height", self.bounds.get("height", 0)) or 0)


@dataclass(frozen=True)
class TaskbarItem:
    owner: str
    pid: int
    title: str
    window_count: int
    window_ids: list[int]
    is_frontmost: bool = False
    bundle_id: str = ""
    app_path: str = ""


def visible_windows(records: list[WindowRecord], current_pid: int) -> list[WindowRecord]:
    visible = []
    for record in records:
        owner = record.owner.strip()
        if not owner or owner in IGNORED_OWNERS:
            continue
        if record.pid == current_pid:
            continue
        if record.layer != 0:
            continue
        if not record.is_on_screen:
            continue
        if record.width < MIN_WINDOW_WIDTH or record.height < MIN_WINDOW_HEIGHT:
            continue
        visible.append(record)
    return visible


def build_taskbar_items(windows: list[WindowRecord], frontmost_pid: Optional[int]) -> list[TaskbarItem]:
    by_pid: dict[int, list[WindowRecord]] = {}
    for window in windows:
        by_pid.setdefault(window.pid, []).append(window)

    items = []
    for pid, app_windows in by_pid.items():
        first = app_windows[0]
        title = next((window.title for window in app_windows if window.title), first.owner)
        items.append(
            TaskbarItem(
                owner=first.owner,
                pid=pid,
                title=title,
                window_count=len(app_windows),
                window_ids=[window.window_id for window in app_windows],
                is_frontmost=frontmost_pid == pid,
                bundle_id=first.bundle_id,
                app_path=first.app_path,
            )
        )

    return sorted(
        items,
        key=lambda item: (
            item.owner.lower(),
            item.title.lower(),
            item.pid,
            item.window_ids[0] if item.window_ids else 0,
        ),
    )
