from __future__ import annotations

import threading
from collections.abc import Callable
from typing import TypeVar


T = TypeVar("T")


def should_request_precompute(
    sample_count: int,
    last_requested_samples: int,
    minimum_samples: int,
    delta_samples: int,
) -> bool:
    """Start at the minimum duration, then space later growing-buffer passes."""
    if sample_count < minimum_samples:
        return False
    if last_requested_samples == 0:
        return True
    return sample_count >= last_requested_samples + delta_samples


def _materialize_transcription(callback):
    """Exhaust lazy decoder segments before the scheduler releases its lock."""
    segments, info = callback()
    return list(segments), info


class InferenceScheduler:
    """Serialize local model work and keep stale background jobs behind key-up.

    MLX uses shared Metal resources even when two different Whisper model
    objects are involved. Running preview, precompute, and final inference at
    once can turn a normally quick pass into a very long one under pressure.
    """

    def __init__(self):
        self._condition = threading.Condition()
        self._busy = False
        self._final_requested = False

    def request_finalization(self) -> None:
        with self._condition:
            self._final_requested = True
            self._condition.notify_all()

    def cancel_finalization(self) -> None:
        with self._condition:
            self._final_requested = False
            self._condition.notify_all()

    def run_background(
        self,
        kind: str,
        callback: Callable[[], T],
    ) -> tuple[bool, T | None]:
        if kind not in {"preview", "precompute"}:
            raise ValueError(f"unsupported background inference kind: {kind}")

        with self._condition:
            while self._busy and not self._final_requested:
                self._condition.wait()
            if self._final_requested:
                return False, None
            self._busy = True

        try:
            return True, callback()
        finally:
            with self._condition:
                self._busy = False
                self._condition.notify_all()

    def run_background_transcription(self, kind: str, callback):
        return self.run_background(
            kind,
            lambda: _materialize_transcription(callback),
        )

    def run_final(self, callback: Callable[[], T]) -> T:
        self.request_finalization()
        with self._condition:
            while self._busy:
                self._condition.wait()
            self._busy = True

        try:
            return callback()
        finally:
            with self._condition:
                self._busy = False
                self._final_requested = False
                self._condition.notify_all()

    def run_final_transcription(self, callback):
        return self.run_final(lambda: _materialize_transcription(callback))
