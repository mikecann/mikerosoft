from __future__ import annotations

import threading
from collections.abc import Callable
from typing import TypeVar


T = TypeVar("T")


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
