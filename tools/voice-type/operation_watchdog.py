"""Small watchdog primitives for native operations that Python cannot cancel."""

from __future__ import annotations

from collections.abc import Callable
import threading


def finalization_timeout_seconds(duration_seconds: float) -> float:
    """Allow long recordings more time without ever accepting an infinite wait."""
    return max(30.0, duration_seconds * 2.0)


class OperationWatchdog:
    """Call a recovery hook once if an operation does not report completion.

    Metal and CoreAudio calls cannot be cancelled safely from Python. The
    timeout callback is therefore expected to dump diagnostics and terminate
    the process so launchd can create fresh native state.
    """

    def __init__(
        self,
        *,
        timeout_seconds: float,
        on_timeout: Callable[[], None],
        name: str,
    ) -> None:
        self.timeout_seconds = timeout_seconds
        self._on_timeout = on_timeout
        self._name = name
        self._completed = threading.Event()
        self._start_lock = threading.Lock()
        self._started = False

    def start(self) -> None:
        with self._start_lock:
            if self._started:
                return
            self._started = True
        threading.Thread(
            target=self._wait,
            daemon=True,
            name=f"voice-type-watchdog-{self._name}",
        ).start()

    def complete(self) -> None:
        self._completed.set()

    def _wait(self) -> None:
        if not self._completed.wait(self.timeout_seconds):
            self._on_timeout()
