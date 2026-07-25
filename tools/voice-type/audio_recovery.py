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
        self._finalizations_in_flight = 0
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

    def recover_if_required(self, restart: Callable[[], object]) -> bool:
        """Claim and run the automatic restart once."""
        if not self._claim_restart():
            return False
        try:
            result = restart()
        except Exception:
            self._release_restart_claim()
            raise
        if result is False:
            self._release_restart_claim()
            return False
        return True

    def prepare_finish(
        self,
        finish: Callable[[], T],
        restart: Callable[[], object],
    ) -> Callable[[], T]:
        """Register a finalization now and return the work to run off-thread.

        Registration happens before the worker thread starts. A new key-down
        therefore cannot claim a pending backend restart and kill the
        transcription that is already being finalized.
        """
        with self._lock:
            self._finalizations_in_flight += 1

        def run() -> T:
            try:
                return finish()
            finally:
                should_restart = False
                with self._lock:
                    self._finalizations_in_flight -= 1
                    if (
                        self._finalizations_in_flight == 0
                        and self._restart_required
                        and not self._restart_started
                    ):
                        self._restart_started = True
                        should_restart = True
                if should_restart:
                    try:
                        result = restart()
                    except Exception:
                        self._release_restart_claim()
                        raise
                    if result is False:
                        self._release_restart_claim()

        return run

    def finish_then_recover(
        self,
        finish: Callable[[], T],
        restart: Callable[[], object],
    ) -> T:
        """Finish the captured dictation, then claim one automatic restart."""
        return self.prepare_finish(finish, restart)()

    def _claim_restart(self) -> bool:
        with self._lock:
            if (
                not self._restart_required
                or self._restart_started
                or self._finalizations_in_flight > 0
            ):
                return False
            self._restart_started = True
            return True

    def _release_restart_claim(self) -> None:
        with self._lock:
            self._restart_started = False
