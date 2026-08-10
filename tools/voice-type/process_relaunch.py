from __future__ import annotations

from collections.abc import Callable
import os


RESTART_EXIT_CODE = 75


def command_targets_worker(
    command: str,
    *,
    launcher_path: str,
    app_path: str,
) -> bool:
    """Match the exact worker command without treating paths as regexes."""
    return command.strip() == f"{launcher_path} {app_path}"


def validate_relauncher_files(
    *,
    required_paths: list[str],
    executable_paths: list[str] | None = None,
) -> None:
    """Fail before exiting if the detached relauncher cannot possibly work."""
    for path in required_paths:
        if not os.path.isfile(path):
            raise FileNotFoundError(f"Required restart file is missing: {path}")
    for path in executable_paths or []:
        if not os.access(path, os.X_OK):
            raise PermissionError(f"Required restart launcher is not executable: {path}")


def restart_current_process(
    *,
    managed_by_supervisor: bool,
    spawn: Callable[[], None],
    exit_process: Callable[[int], None],
    on_error: Callable[[Exception], None] | None = None,
) -> bool:
    """Hand off a restart, then guarantee that the poisoned process exits."""
    if not managed_by_supervisor:
        try:
            spawn()
        except Exception as error:
            # Keep the existing process alive if there is no supervisor and we
            # could not prove that a replacement was handed off.
            if on_error is not None:
                on_error(error)
            return False
    exit_process(RESTART_EXIT_CODE)
    return True
