"""Durable, local history for completed Voice Type transcriptions."""

from __future__ import annotations

import ast
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import re
import threading


_DONE_LINE = re.compile(
    r"^(?P<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})"
    r"\s+Done \([^)]*\) \[(?P<mode>[^]]+)]\: (?P<text>.+)$"
)


class TranscriptionHistory:
    """Store completed text separately from the rotating diagnostic log.

    JSON Lines keeps each completed dictation durable as soon as it finishes.
    Rewrites only happen when retention is exceeded or legacy log entries are
    imported, and use an atomic replace so a crash cannot destroy the file.
    """

    def __init__(
        self,
        path: str | Path,
        max_entries: int = 500,
        retention_days: int = 30,
        clock=None,
    ):
        self.path = Path(path)
        self.max_entries = max_entries
        self.retention_days = retention_days
        self._clock = clock or (lambda: datetime.now().astimezone())
        self._lock = threading.Lock()

    def append(
        self,
        text: str,
        mode: str,
        *,
        created_at: str | None = None,
    ) -> bool:
        cleaned = text.strip()
        if not cleaned:
            return False
        entry = {
            "created_at": created_at or self._clock().isoformat(timespec="seconds"),
            "mode": mode,
            "text": cleaned,
        }
        if not self._is_retained(entry):
            return False
        with self._lock:
            entries = self._load_oldest_first()
            if self._key(entry) in {self._key(item) for item in entries}:
                return False
            entries.append(entry)
            if len(entries) > self.max_entries:
                entries = entries[-self.max_entries :]
                self._write_atomic(entries)
            else:
                self.path.parent.mkdir(parents=True, exist_ok=True)
                with self.path.open("a", encoding="utf-8") as history_file:
                    history_file.write(json.dumps(entry, ensure_ascii=False) + "\n")
                    history_file.flush()
                    os.fsync(history_file.fileno())
        return True

    def load(self) -> list[dict[str, str]]:
        with self._lock:
            return sorted(
                self._load_oldest_first(),
                key=lambda item: item["created_at"],
                reverse=True,
            )

    def import_completed_log(self, log_path: str | Path) -> int:
        """Seed history from any completed transcriptions still in the old log."""
        try:
            lines = Path(log_path).read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            return 0

        candidates: list[dict[str, str]] = []
        for line in lines:
            match = _DONE_LINE.match(line)
            if not match:
                continue
            try:
                text = ast.literal_eval(match.group("text"))
            except (SyntaxError, ValueError):
                continue
            if not isinstance(text, str) or not text.strip():
                continue
            candidates.append(
                {
                    "created_at": match.group("timestamp").replace(" ", "T", 1),
                    "mode": match.group("mode"),
                    "text": text.strip(),
                }
            )

        with self._lock:
            entries = self._load_oldest_first()
            known = {self._key(item) for item in entries}
            imported = 0
            for entry in candidates:
                if not self._is_retained(entry):
                    continue
                if self._key(entry) in known:
                    continue
                entries.append(entry)
                known.add(self._key(entry))
                imported += 1
            if imported:
                entries.sort(key=lambda item: item["created_at"])
                self._write_atomic(entries[-self.max_entries :])
            return imported

    @staticmethod
    def _key(entry: dict[str, str]) -> tuple[str, str, str]:
        # The live writer includes a UTC offset while timestamps recovered
        # from the old log do not. The first 19 characters identify the same
        # local second and prevent the next startup from importing a duplicate.
        return entry["created_at"][:19], entry["mode"], entry["text"]

    def _load_oldest_first(self) -> list[dict[str, str]]:
        try:
            lines = self.path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            return []

        entries: list[dict[str, str]] = []
        known: set[tuple[str, str, str]] = set()
        needs_compaction = False
        for line in lines:
            try:
                item = json.loads(line)
            except (json.JSONDecodeError, TypeError):
                needs_compaction = True
                continue
            if not isinstance(item, dict):
                needs_compaction = True
                continue
            if not all(isinstance(item.get(key), str) for key in ("created_at", "mode", "text")):
                needs_compaction = True
                continue
            if item["text"].strip():
                entry = {
                    "created_at": item["created_at"],
                    "mode": item["mode"],
                    "text": item["text"],
                }
                if not self._is_retained(entry):
                    needs_compaction = True
                    continue
                key = self._key(entry)
                if key not in known:
                    entries.append(entry)
                    known.add(key)
                else:
                    needs_compaction = True
            else:
                needs_compaction = True

        retained = entries[-self.max_entries :]
        if len(retained) != len(entries):
            needs_compaction = True
        if needs_compaction:
            self._write_atomic(retained)
        return retained

    def _is_retained(self, entry: dict[str, str]) -> bool:
        try:
            created_at = datetime.fromisoformat(entry["created_at"])
        except (TypeError, ValueError):
            return False
        now = self._clock()
        if now.tzinfo is None:
            now = now.astimezone()
        if created_at.tzinfo is None:
            # Timestamps recovered from the old log are in the machine's local
            # time. Give them the same zone as "now" before comparing.
            created_at = created_at.replace(tzinfo=now.tzinfo)
        cutoff = now - timedelta(days=self.retention_days)
        return created_at >= cutoff

    def _write_atomic(self, entries: list[dict[str, str]]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(self.path.suffix + ".tmp")
        with temporary.open("w", encoding="utf-8") as history_file:
            for entry in entries:
                history_file.write(json.dumps(entry, ensure_ascii=False) + "\n")
            history_file.flush()
            os.fsync(history_file.fileno())
        os.replace(temporary, self.path)
