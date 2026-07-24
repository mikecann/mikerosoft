from __future__ import annotations

import threading
from collections.abc import Callable
from typing import TypeVar


T = TypeVar("T")


class AudioBackendRecovery:
    """Tracks whether CoreAudio is safe to reuse after closing a stream.

    A timed-out PortAudio close cannot be cancelled safely. Its abandoned
    thread may still own a CoreAudio HAL mutex, so opening another stream in
    the same process can deadlock too. Once that happens, the process must be
    treated as poisoned and relaunched after the current dictation finishes.
    """

    def __init__(self) -> None:
        self._restart_required = False
        self._restart_started = False
        self._lock = threading.Lock()

    @property
    def can_open_stream(self) -> bool:
        with self._lock:
            return not self._restart_required

    @property
    def restart_required(self) -> bool:
        with self._lock:
            return self._restart_required

    def note_close_finished(self) -> None:
        # A later return from an already timed-out close does not prove the HAL
        # is healthy again. Keep the poisoned state sticky until process exit.
        return

    def note_close_timeout(self) -> None:
        with self._lock:
            self._restart_required = True

    def note_open_failure(self) -> None:
        # PortAudio/CoreAudio can leave the process-wide backend unusable after
        # Pa_OpenStream fails. Do not keep retrying inside the same process.
        with self._lock:
            self._restart_required = True

    def recover_if_required(self, restart: Callable[[], None]) -> bool:
        """Claim and run the automatic restart once."""
        if not self._claim_restart():
            return False
        restart()
        return True

    def finish_then_recover(
        self,
        finish: Callable[[], T],
        restart: Callable[[], None],
        *,
        requested: bool | None = None,
    ) -> T:
        """Finish the captured dictation, then claim one automatic restart."""
        try:
            return finish()
        finally:
            should_restart = self.restart_required if requested is None else requested
            if should_restart:
                self.recover_if_required(restart)

    def _claim_restart(self) -> bool:
        with self._lock:
            if not self._restart_required or self._restart_started:
                return False
            self._restart_started = True
            return True
