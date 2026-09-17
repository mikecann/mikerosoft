"""Explicit-confirmation speaker assignments; predictions never enroll themselves."""

from __future__ import annotations

import sqlite3
import json
import math
from datetime import UTC, datetime
from pathlib import Path

from .db import closing_connection


STRONG_MATCH_THRESHOLD = 0.82
TENTATIVE_MATCH_THRESHOLD = 0.65
MATCH_MARGIN = 0.08


class SpeakerRegistry:
    def __init__(self, database: Path | str):
        self.database = Path(database)
        with closing_connection(
            lambda: sqlite3.connect(self.database, timeout=30, isolation_level=None),
        ) as connection:
            # Schema inspection and ALTER must share the same writer lock. The
            # app can invoke review while the service starts after an upgrade.
            connection.execute("BEGIN IMMEDIATE")
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
                dimension INTEGER NOT NULL, source_meeting_id TEXT,
                source_revision INTEGER, source_speaker_id TEXT)""",
            )
            connection.execute(
                """CREATE TABLE IF NOT EXISTS observed_voices (
                meeting_id TEXT NOT NULL, manifest_revision INTEGER NOT NULL,
                speaker_id TEXT NOT NULL, embedding_json TEXT NOT NULL,
                model_id TEXT NOT NULL, dimension INTEGER NOT NULL,
                PRIMARY KEY(meeting_id, manifest_revision, speaker_id))""",
            )
            connection.execute(
                """CREATE TABLE IF NOT EXISTS speaker_refreshes (
                meeting_id TEXT NOT NULL, manifest_revision INTEGER NOT NULL,
                generation INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT, requested_at TEXT NOT NULL,
                PRIMARY KEY(meeting_id, manifest_revision))""",
            )
            self._ensure_columns(connection, "voice_profiles", {
                "model_id": "TEXT NOT NULL DEFAULT 'legacy'",
                "dimension": "INTEGER NOT NULL DEFAULT 0",
                "source_meeting_id": "TEXT",
                "source_revision": "INTEGER",
                "source_speaker_id": "TEXT",
            })
            self._ensure_columns(connection, "observed_voices", {"model_id": "TEXT NOT NULL DEFAULT 'legacy'", "dimension": "INTEGER NOT NULL DEFAULT 0"})
            self._backfill_profile_provenance(connection)
            self._deduplicate_profile_sources(connection)
            connection.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS voice_profiles_source "
                "ON voice_profiles(source_meeting_id, source_revision, source_speaker_id) "
                "WHERE source_meeting_id IS NOT NULL",
            )
            connection.commit()

    @staticmethod
    def _ensure_columns(connection, table: str, columns: dict[str, str]) -> None:
        existing = {row[1] for row in connection.execute(f"PRAGMA table_info({table})")}
        for name, declaration in columns.items():
            if name not in existing:
                connection.execute(f"ALTER TABLE {table} ADD COLUMN {name} {declaration}")

    @staticmethod
    def _backfill_profile_provenance(connection: sqlite3.Connection) -> None:
        legacy_rows = connection.execute(
            "SELECT rowid, display_name, embedding_json, model_id, dimension "
            "FROM voice_profiles WHERE source_meeting_id IS NULL",
        ).fetchall()
        for rowid, name, embedding_json, model_id, dimension in legacy_rows:
            matches = connection.execute(
                "SELECT DISTINCT observed.meeting_id, observed.manifest_revision, "
                "observed.speaker_id FROM observed_voices AS observed "
                "JOIN speaker_assignments AS assignment ON "
                "assignment.meeting_id=observed.meeting_id AND "
                "assignment.manifest_revision=observed.manifest_revision AND "
                "assignment.speaker_id=observed.speaker_id "
                "WHERE assignment.display_name=? AND observed.embedding_json=? AND "
                "observed.model_id=? AND observed.dimension=?",
                (name, embedding_json, model_id, dimension),
            ).fetchall()
            # An exact row can only prove provenance when it identifies one
            # confirmed observation. Ambiguous legacy rows remain unproven.
            if len(matches) != 1:
                continue
            meeting_id, revision, speaker_id = matches[0]
            existing = connection.execute(
                "SELECT rowid FROM voice_profiles WHERE source_meeting_id=? AND "
                "source_revision=? AND source_speaker_id=? AND rowid<>?",
                (meeting_id, revision, speaker_id, rowid),
            ).fetchone()
            if existing is not None:
                connection.execute("DELETE FROM voice_profiles WHERE rowid=?", (rowid,))
                continue
            connection.execute(
                "UPDATE voice_profiles SET source_meeting_id=?, source_revision=?, "
                "source_speaker_id=? WHERE rowid=?",
                (meeting_id, revision, speaker_id, rowid),
            )

    @staticmethod
    def _deduplicate_profile_sources(connection: sqlite3.Connection) -> None:
        duplicates = connection.execute(
            "SELECT source_meeting_id, source_revision, source_speaker_id "
            "FROM voice_profiles WHERE source_meeting_id IS NOT NULL "
            "GROUP BY source_meeting_id, source_revision, source_speaker_id "
            "HAVING COUNT(*) > 1",
        ).fetchall()
        for source in duplicates:
            rows = connection.execute(
                "SELECT rowid FROM voice_profiles WHERE source_meeting_id=? AND "
                "source_revision=? AND source_speaker_id=? "
                "ORDER BY confirmed_at DESC, rowid DESC",
                source,
            ).fetchall()
            connection.executemany(
                "DELETE FROM voice_profiles WHERE rowid=?",
                rows[1:],
            )

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

    def enroll_confirmed(
        self,
        name: str,
        embedding: list[float],
        model_id: str = "test",
        *,
        source_meeting_id: str | None = None,
        source_revision: int | None = None,
        source_speaker_id: str | None = None,
    ) -> None:
        confirmed = datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            self._enroll_confirmed_with_connection(
                connection,
                name,
                embedding,
                model_id,
                confirmed,
                source_meeting_id=source_meeting_id,
                source_revision=source_revision,
                source_speaker_id=source_speaker_id,
            )

    @staticmethod
    def _enroll_confirmed_with_connection(
        connection: sqlite3.Connection,
        name: str,
        embedding: list[float],
        model_id: str,
        confirmed: str,
        *,
        source_meeting_id: str | None,
        source_revision: int | None,
        source_speaker_id: str | None,
    ) -> None:
        if not name.strip() or not embedding or not all(math.isfinite(value) for value in embedding):
            raise ValueError("A confirmed profile needs a name and finite embedding.")
        provenance = (source_meeting_id, source_revision, source_speaker_id)
        if any(value is not None for value in provenance) and not (
            isinstance(source_meeting_id, str)
            and source_meeting_id.strip()
            and isinstance(source_revision, int)
            and not isinstance(source_revision, bool)
            and source_revision >= 1
            and isinstance(source_speaker_id, str)
            and source_speaker_id.strip()
        ):
            raise ValueError("Confirmed profile provenance must be complete.")
        values = (
            name.strip(),
            json.dumps(embedding),
            confirmed,
            model_id,
            len(embedding),
        )
        if source_meeting_id is None:
            connection.execute(
                "INSERT INTO voice_profiles "
                "(display_name,embedding_json,confirmed_at,model_id,dimension) "
                "VALUES (?, ?, ?, ?, ?)",
                values,
            )
            return
        updated = connection.execute(
            "UPDATE voice_profiles SET display_name=?, embedding_json=?, "
            "confirmed_at=?, model_id=?, dimension=? WHERE "
            "source_meeting_id=? AND source_revision=? AND source_speaker_id=?",
            values + (source_meeting_id, source_revision, source_speaker_id),
        )
        if updated.rowcount == 0:
            connection.execute(
                "INSERT INTO voice_profiles "
                "(display_name,embedding_json,confirmed_at,model_id,dimension,"
                "source_meeting_id,source_revision,source_speaker_id) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                values + (source_meeting_id, source_revision, source_speaker_id),
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

    def request_refresh(self, meeting_id: str, revision: int) -> None:
        self._validate_refresh_identity(meeting_id, revision)
        requested_at = datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        with closing_connection(
            lambda: sqlite3.connect(self.database, timeout=30, isolation_level=None),
        ) as connection:
            connection.execute("BEGIN IMMEDIATE")
            self._request_refresh_with_connection(
                connection,
                meeting_id,
                revision,
                requested_at,
            )
            connection.commit()

    @staticmethod
    def _validate_refresh_identity(meeting_id: str, revision: int) -> None:
        if (
            not isinstance(meeting_id, str)
            or not meeting_id.strip()
            or not isinstance(revision, int)
            or isinstance(revision, bool)
            or revision < 1
        ):
            raise ValueError("A speaker refresh needs a meeting_id and positive revision.")

    @staticmethod
    def _request_refresh_with_connection(
        connection: sqlite3.Connection,
        meeting_id: str,
        revision: int,
        requested_at: str,
    ) -> None:
        connection.execute(
            "INSERT INTO speaker_refreshes "
            "(meeting_id,manifest_revision,generation,attempts,last_error,requested_at) "
            "VALUES (?, ?, 1, 0, NULL, ?) ON CONFLICT(meeting_id,manifest_revision) "
            "DO UPDATE SET generation=speaker_refreshes.generation+1, "
            "last_error=NULL, requested_at=excluded.requested_at",
            (meeting_id, revision, requested_at),
        )

    def confirm_observation(self, meeting_id: str, revision: int, speaker_id: str, name: str) -> bool:
        self._validate_refresh_identity(meeting_id, revision)
        if not isinstance(speaker_id, str) or not speaker_id.strip() or not name.strip():
            raise ValueError("speaker_id and name must be nonempty.")
        confirmed = datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        with closing_connection(
            lambda: sqlite3.connect(self.database, timeout=30, isolation_level=None),
        ) as connection:
            connection.execute("BEGIN IMMEDIATE")
            record = connection.execute(
                "SELECT embedding_json, model_id FROM observed_voices WHERE "
                "meeting_id=? AND manifest_revision=? AND speaker_id=?",
                (meeting_id, revision, speaker_id),
            ).fetchone()
            connection.execute(
                "INSERT INTO speaker_assignments "
                "(meeting_id,manifest_revision,speaker_id,display_name,confirmed_at) "
                "VALUES (?, ?, ?, ?, ?) ON CONFLICT(meeting_id,manifest_revision,speaker_id) "
                "DO UPDATE SET display_name=excluded.display_name, "
                "confirmed_at=excluded.confirmed_at",
                (meeting_id, revision, speaker_id, name.strip(), confirmed),
            )
            if record is not None:
                self._enroll_confirmed_with_connection(
                    connection,
                    name,
                    json.loads(record[0]),
                    record[1],
                    confirmed,
                    source_meeting_id=meeting_id,
                    source_revision=revision,
                    source_speaker_id=speaker_id,
                )
            self._request_refresh_with_connection(
                connection,
                meeting_id,
                revision,
                confirmed,
            )
            connection.commit()
        return record is not None

    def review_match(
        self,
        embedding: list[float],
        model_id: str = "test",
        exclude_meeting_id: str | None = None,
    ) -> dict[str, str | float | int | None]:
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            return self.review_match_from_connection(
                connection,
                embedding,
                model_id=model_id,
                exclude_meeting_id=exclude_meeting_id,
            )

    @classmethod
    def review_match_from_connection(
        cls,
        connection: sqlite3.Connection,
        embedding: list[float],
        model_id: str = "test",
        exclude_meeting_id: str | None = None,
    ) -> dict[str, str | float | int | None]:
        if (
            not isinstance(embedding, (list, tuple))
            or not embedding
            or any(
                not isinstance(value, (int, float))
                or isinstance(value, bool)
                or not math.isfinite(value)
                for value in embedding
            )
        ):
            raise ValueError("A review match needs a nonempty finite embedding.")
        if not isinstance(model_id, str) or not model_id.strip():
            raise ValueError("A review match needs a nonempty model_id.")

        query = (
            "SELECT display_name, embedding_json, source_meeting_id "
            "FROM voice_profiles WHERE model_id=? AND dimension=? "
            "AND source_meeting_id IS NOT NULL AND source_revision IS NOT NULL "
            "AND source_speaker_id IS NOT NULL"
        )
        parameters: list[object] = [model_id, len(embedding)]
        if exclude_meeting_id is not None:
            query += " AND source_meeting_id<>?"
            parameters.append(exclude_meeting_id)
        rows = connection.execute(query, parameters).fetchall()

        by_name: dict[str, dict[str, object]] = {}
        for name, raw, source_meeting_id in rows:
            try:
                stored = json.loads(raw)
            except (TypeError, json.JSONDecodeError):
                continue
            if (
                not isinstance(stored, list)
                or len(stored) != len(embedding)
                or any(
                    not isinstance(value, (int, float))
                    or isinstance(value, bool)
                    or not math.isfinite(value)
                    for value in stored
                )
            ):
                continue
            score = cls._cosine(embedding, stored)
            if not math.isfinite(score):
                continue
            candidate = by_name.setdefault(
                name,
                {"score": -1.0, "meetings": set()},
            )
            candidate["score"] = max(float(candidate["score"]), score)
            candidate["meetings"].add(source_meeting_id)

        empty = {
            "suggested_name": None,
            "automatic_name": None,
            "suggestion_kind": None,
            "suggestion_score": None,
            "suggestion_margin": None,
            "confirmation_count": 0,
        }
        if not by_name:
            return empty

        ranked = sorted(
            (
                (float(candidate["score"]), name, len(candidate["meetings"]))
                for name, candidate in by_name.items()
            ),
            reverse=True,
        )
        score, name, confirmation_count = ranked[0]
        margin = score - ranked[1][0] if len(ranked) > 1 else None
        clears_margin = margin is None or margin >= MATCH_MARGIN
        result = {
            **empty,
            "suggestion_score": score,
            "suggestion_margin": margin,
            "confirmation_count": confirmation_count,
        }
        if score >= STRONG_MATCH_THRESHOLD and clears_margin and confirmation_count >= 1:
            result.update({
                "suggested_name": name,
                "automatic_name": name,
                "suggestion_kind": "strong",
            })
        elif score >= TENTATIVE_MATCH_THRESHOLD and clears_margin and confirmation_count >= 2:
            result.update({
                "suggested_name": name,
                "suggestion_kind": "tentative",
            })
        return result

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

    def suggest(
        self,
        embedding: list[float],
        threshold: float = STRONG_MATCH_THRESHOLD,
        margin: float = MATCH_MARGIN,
        model_id: str = "test",
    ) -> str | None:
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
