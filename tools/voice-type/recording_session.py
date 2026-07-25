from __future__ import annotations

import threading
from typing import TypeVar


T = TypeVar("T")


class RecordingSession:
    """Track whether the current key hold started a real recording.

    The physical key can still be released after CoreAudio rejects a stream.
    That release must not finalize audio left over from an earlier dictation.
    """

    def __init__(self) -> None:
        self._active = False

    def note_start_result(self, started: bool) -> None:
        self._active = started

    def finish_on_release(self) -> bool:
        was_active = self._active
        self._active = False
        return was_active


class AudioFrameBuffer:
    """Thread-safe audio frames belonging only to one successful key hold."""

    def __init__(self) -> None:
        self._frames: list[T] = []
        self._recording = False
        self._lock = threading.Lock()

    def reset_for_start_attempt(self) -> None:
        """Discard old audio before trying to open a new microphone stream."""
        with self._lock:
            self._frames = []
            self._recording = False

    def mark_started(self) -> None:
        with self._lock:
            self._frames = []
            self._recording = True

    def append(self, frame: T) -> None:
        with self._lock:
            if self._recording:
                self._frames.append(frame)

    def snapshot(self) -> list[T]:
        with self._lock:
            return list(self._frames)

    def stop(self) -> list[T]:
        with self._lock:
            was_recording = self._recording
            self._recording = False
            frames = list(self._frames) if was_recording else []
            self._frames = []
            return frames
