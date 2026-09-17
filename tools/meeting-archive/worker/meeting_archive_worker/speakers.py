"""Explicit-confirmation speaker assignments; predictions never enroll themselves."""

from __future__ import annotations

import sqlite3
import json
import math
from datetime import UTC, datetime
from pathlib import Path

from .db import closing_connection


class SpeakerRegistry:
    def __init__(self, database: Path | str):
        self.database = Path(database)
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            connection.execute(
                """CREATE TABLE IF NOT EXISTS speaker_assignments (
                meeting_id TEXT NOT NULL, manifest_revision INTEGER NOT NULL,
                speaker_id TEXT NOT NULL, display_name TEXT NOT NULL,
                confirmed_at TEXT NOT NULL, PRIMARY KEY(meeting_id, manifest_revision, speaker_id))""",
            )
            connection.execute(
                """CREATE TABLE IF NOT EXISTS voice_profiles (
                display_name TEXT NOT NULL, embedding_json TEXT NOT NULL,
                confirmed_at TEXT NOT NULL, model_id TEXT NOT NULL,
                dimension INTEGER NOT NULL)""",
            )
            connection.execute(
                """CREATE TABLE IF NOT EXISTS observed_voices (
                meeting_id TEXT NOT NULL, manifest_revision INTEGER NOT NULL,
                speaker_id TEXT NOT NULL, embedding_json TEXT NOT NULL,
                model_id TEXT NOT NULL, dimension INTEGER NOT NULL,
                PRIMARY KEY(meeting_id, manifest_revision, speaker_id))""",
            )
            self._ensure_columns(connection, "voice_profiles", {"model_id": "TEXT NOT NULL DEFAULT 'legacy'", "dimension": "INTEGER NOT NULL DEFAULT 0"})
            self._ensure_columns(connection, "observed_voices", {"model_id": "TEXT NOT NULL DEFAULT 'legacy'", "dimension": "INTEGER NOT NULL DEFAULT 0"})

    @staticmethod
    def _ensure_columns(connection, table: str, columns: dict[str, str]) -> None:
        existing = {row[1] for row in connection.execute(f"PRAGMA table_info({table})")}
        for name, declaration in columns.items():
            if name not in existing:
                connection.execute(f"ALTER TABLE {table} ADD COLUMN {name} {declaration}")

    def identify(self, meeting_id: str, revision: int, speaker_id: str, name: str) -> None:
        if not speaker_id.strip() or not name.strip():
            raise ValueError("speaker_id and name must be nonempty.")
        confirmed = datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            connection.execute(
                "INSERT INTO speaker_assignments VALUES (?, ?, ?, ?, ?) "
                "ON CONFLICT(meeting_id,manifest_revision,speaker_id) DO UPDATE SET "
                "display_name=excluded.display_name, confirmed_at=excluded.confirmed_at",
                (meeting_id, revision, speaker_id, name.strip(), confirmed),
            )

    def assignments(self, meeting_id: str, revision: int) -> dict[str, str]:
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            rows = connection.execute(
                "SELECT speaker_id, display_name FROM speaker_assignments "
                "WHERE meeting_id=? AND manifest_revision=? ORDER BY speaker_id",
                (meeting_id, revision),
            ).fetchall()
        return dict(rows)

    def enroll_confirmed(self, name: str, embedding: list[float], model_id: str = "test") -> None:
        if not name.strip() or not embedding or not all(math.isfinite(value) for value in embedding):
            raise ValueError("A confirmed profile needs a name and finite embedding.")
        confirmed = datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            connection.execute(
                "INSERT INTO voice_profiles VALUES (?, ?, ?, ?, ?)",
                (name.strip(), json.dumps(embedding), confirmed, model_id, len(embedding)),
            )

    def save_observation(self, meeting_id: str, revision: int, speaker_id: str, embedding: list[float], model_id: str = "test") -> None:
        if not embedding or not all(math.isfinite(value) for value in embedding):
            raise ValueError("An observed voice needs a finite embedding.")
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            connection.execute(
                "INSERT INTO observed_voices VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT "
                "(meeting_id,manifest_revision,speaker_id) DO UPDATE SET embedding_json=excluded.embedding_json, model_id=excluded.model_id, dimension=excluded.dimension",
                (meeting_id, revision, speaker_id, json.dumps(embedding), model_id, len(embedding)),
            )

    def observation(self, meeting_id: str, revision: int, speaker_id: str) -> list[float] | None:
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            row = connection.execute(
                "SELECT embedding_json FROM observed_voices WHERE meeting_id=? AND manifest_revision=? AND speaker_id=?",
                (meeting_id, revision, speaker_id),
            ).fetchone()
        return json.loads(row[0]) if row else None

    def observation_record(self, meeting_id: str, revision: int, speaker_id: str):
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            row = connection.execute(
                "SELECT embedding_json, model_id FROM observed_voices WHERE meeting_id=? AND manifest_revision=? AND speaker_id=?",
                (meeting_id, revision, speaker_id),
            ).fetchone()
        return (json.loads(row[0]), row[1]) if row else None

    def confirm_observation(self, meeting_id: str, revision: int, speaker_id: str, name: str) -> bool:
        self.identify(meeting_id, revision, speaker_id, name)
        record = self.observation_record(meeting_id, revision, speaker_id)
        if record is None:
            return False
        embedding, model_id = record
        self.enroll_confirmed(name, embedding, model_id)
        return True

    def ranked_suggestions(self, embedding: list[float], model_id: str = "test") -> list[tuple[float, str]]:
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            rows = connection.execute(
                "SELECT display_name, embedding_json FROM voice_profiles WHERE model_id=? AND dimension=?",
                (model_id, len(embedding)),
            ).fetchall()
        by_name: dict[str, float] = {}
        for name, raw in rows:
            by_name[name] = max(by_name.get(name, -1.0), self._cosine(embedding, json.loads(raw)))
        return sorted(
            ((score, name) for name, score in by_name.items()),
            reverse=True,
        )

    def suggest(self, embedding: list[float], threshold: float = 0.82, margin: float = 0.08, model_id: str = "test") -> str | None:
        scores = self.ranked_suggestions(embedding, model_id)
        if not scores or scores[0][0] < threshold:
            return None
        runner_up = scores[1][0] if len(scores) > 1 else -1.0
        return scores[0][1] if scores[0][0] - runner_up >= margin else None

    @staticmethod
    def _cosine(left: list[float], right: list[float]) -> float:
        if len(left) != len(right) or not left:
            return -1.0
        left_norm = math.sqrt(sum(value * value for value in left))
        right_norm = math.sqrt(sum(value * value for value in right))
        if left_norm == 0 or right_norm == 0:
            return -1.0
        return sum(a * b for a, b in zip(left, right)) / (left_norm * right_norm)
