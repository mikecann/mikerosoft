from __future__ import annotations

import json
import math
import sqlite3
import tempfile
import unittest
import uuid
from contextlib import closing
from pathlib import Path

from meeting_archive_worker.speakers import SpeakerRegistry


def embedding_with_cosine(score: float) -> list[float]:
    return [score, math.sqrt(1.0 - score * score)]


class SpeakerReviewMatchingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.database = Path(self.temporary.name) / "worker.sqlite"
        self.registry = SpeakerRegistry(self.database)
        self.query = [1.0, 0.0]

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _confirm(
        self,
        name: str,
        embedding: list[float],
        *,
        meeting_id: str | None = None,
        model_id: str = "model@1",
    ) -> str:
        meeting_id = meeting_id or str(uuid.uuid4())
        speaker_id = "microphone:SPEAKER_00"
        self.registry.save_observation(
            meeting_id,
            1,
            speaker_id,
            embedding,
            model_id,
        )
        self.assertTrue(
            self.registry.confirm_observation(meeting_id, 1, speaker_id, name)
        )
        return meeting_id

    def test_review_thresholds_separate_tentative_and_strong_matches(self) -> None:
        self._confirm("Mike Cann", embedding_with_cosine(0.63))
        self._confirm("Mike Cann", embedding_with_cosine(0.62))

        below = self.registry.review_match(self.query, model_id="model@1")
        self.assertEqual(
            below,
            {
                "suggested_name": None,
                "automatic_name": None,
                "suggestion_kind": None,
                "suggestion_score": 0.63,
                "suggestion_margin": None,
                "confirmation_count": 2,
            },
        )

        self._confirm("Mike Cann", embedding_with_cosine(0.72))
        tentative = self.registry.review_match(self.query, model_id="model@1")
        self.assertEqual(tentative["suggested_name"], "Mike Cann")
        self.assertIsNone(tentative["automatic_name"])
        self.assertEqual(tentative["suggestion_kind"], "tentative")
        self.assertAlmostEqual(tentative["suggestion_score"], 0.72)
        self.assertIsNone(tentative["suggestion_margin"])
        self.assertEqual(tentative["confirmation_count"], 3)

        self._confirm("Mike Cann", embedding_with_cosine(0.82))
        strong = self.registry.review_match(self.query, model_id="model@1")
        self.assertEqual(strong["suggested_name"], "Mike Cann")
        self.assertEqual(strong["automatic_name"], "Mike Cann")
        self.assertEqual(strong["suggestion_kind"], "strong")
        self.assertAlmostEqual(strong["suggestion_score"], 0.82)
        self.assertEqual(strong["confirmation_count"], 4)

    def test_competing_candidate_must_clear_margin(self) -> None:
        self._confirm("Mike Cann", embedding_with_cosine(0.72))
        self._confirm("Mike Cann", embedding_with_cosine(0.70))
        self._confirm("James", embedding_with_cosine(0.68))

        match = self.registry.review_match(self.query, model_id="model@1")

        self.assertIsNone(match["suggested_name"])
        self.assertIsNone(match["automatic_name"])
        self.assertIsNone(match["suggestion_kind"])
        self.assertAlmostEqual(match["suggestion_score"], 0.72)
        self.assertAlmostEqual(match["suggestion_margin"], 0.04)
        self.assertEqual(match["confirmation_count"], 2)

    def test_tentative_match_counts_distinct_source_meetings_not_speakers(self) -> None:
        meeting_id = str(uuid.uuid4())
        for speaker_id, score in (
            ("microphone:SPEAKER_00", 0.72),
            ("microphone:SPEAKER_01", 0.70),
        ):
            self.registry.save_observation(
                meeting_id,
                1,
                speaker_id,
                embedding_with_cosine(score),
                "model@1",
            )
            self.assertTrue(
                self.registry.confirm_observation(
                    meeting_id,
                    1,
                    speaker_id,
                    "Mike Cann",
                )
            )

        match = self.registry.review_match(self.query, model_id="model@1")

        self.assertIsNone(match["suggested_name"])
        self.assertAlmostEqual(match["suggestion_score"], 0.72)
        self.assertEqual(match["confirmation_count"], 1)

    def test_repeat_confirmation_deduplicates_and_rename_replaces_old_name(self) -> None:
        meeting_id = self._confirm("Mike", self.query)
        self.assertTrue(
            self.registry.confirm_observation(
                meeting_id,
                1,
                "microphone:SPEAKER_00",
                "Mike",
            )
        )
        self.assertTrue(
            self.registry.confirm_observation(
                meeting_id,
                1,
                "microphone:SPEAKER_00",
                "Mike Cann",
            )
        )

        with closing(sqlite3.connect(self.database)) as connection:
            profiles = connection.execute(
                "SELECT display_name, source_meeting_id FROM voice_profiles"
            ).fetchall()
        self.assertEqual(profiles, [("Mike Cann", meeting_id)])
        self.assertEqual(
            self.registry.assignments(meeting_id, 1),
            {"microphone:SPEAKER_00": "Mike Cann"},
        )

    def test_excluding_current_meeting_prevents_self_match(self) -> None:
        meeting_id = self._confirm("Mike Cann", self.query)

        included = self.registry.review_match(self.query, model_id="model@1")
        excluded = self.registry.review_match(
            self.query,
            model_id="model@1",
            exclude_meeting_id=meeting_id,
        )

        self.assertEqual(included["suggestion_kind"], "strong")
        self.assertEqual(excluded["suggested_name"], None)
        self.assertEqual(excluded["confirmation_count"], 0)

    def test_model_mismatch_and_unproven_profiles_do_not_enter_review_match(self) -> None:
        self._confirm("Wrong model", self.query, model_id="other@1")
        self.registry.enroll_confirmed("Legacy without provenance", self.query, "model@1")

        match = self.registry.review_match(self.query, model_id="model@1")

        self.assertEqual(match["suggested_name"], None)
        self.assertEqual(match["suggestion_score"], None)
        self.assertEqual(match["confirmation_count"], 0)
        self.assertEqual(self.registry.suggest(self.query, model_id="model@1"), "Legacy without provenance")

    def test_connection_helper_is_read_only_and_rejects_invalid_query_embedding(self) -> None:
        self._confirm("Mike Cann", self.query)
        with closing(
            sqlite3.connect(self.database.resolve().as_uri() + "?mode=ro", uri=True)
        ) as connection:
            match = SpeakerRegistry.review_match_from_connection(
                connection,
                self.query,
                model_id="model@1",
            )
        self.assertEqual(match["automatic_name"], "Mike Cann")

        for invalid in ([], [float("nan"), 0.0], [float("inf"), 0.0]):
            with self.subTest(invalid=invalid):
                with self.assertRaises(ValueError):
                    self.registry.review_match(invalid, model_id="model@1")

    def test_unambiguous_legacy_profile_is_backfilled_from_exact_observation(self) -> None:
        database = Path(self.temporary.name) / "legacy.sqlite"
        meeting_id = str(uuid.uuid4())
        self._create_legacy_database(
            database,
            [(meeting_id, "Mike Cann", self.query)],
            [("Mike Cann", self.query), ("Mike Cann", self.query)],
        )

        registry = SpeakerRegistry(database)

        match = registry.review_match(self.query, model_id="model@1")
        self.assertEqual(match["automatic_name"], "Mike Cann")
        self.assertEqual(match["confirmation_count"], 1)
        with closing(sqlite3.connect(database)) as connection:
            profiles = connection.execute(
                "SELECT source_meeting_id, source_revision, source_speaker_id "
                "FROM voice_profiles"
            ).fetchall()
        self.assertEqual(
            profiles,
            [(meeting_id, 1, "microphone:SPEAKER_00")],
        )

    def test_ambiguous_legacy_profile_is_not_counted_as_confirmed_evidence(self) -> None:
        database = Path(self.temporary.name) / "ambiguous.sqlite"
        first = str(uuid.uuid4())
        second = str(uuid.uuid4())
        self._create_legacy_database(
            database,
            [
                (first, "Mike Cann", self.query),
                (second, "Mike Cann", self.query),
            ],
            [("Mike Cann", self.query)],
        )

        registry = SpeakerRegistry(database)

        match = registry.review_match(self.query, model_id="model@1")
        self.assertIsNone(match["suggested_name"])
        self.assertEqual(match["confirmation_count"], 0)
        with closing(sqlite3.connect(database)) as connection:
            source = connection.execute(
                "SELECT source_meeting_id FROM voice_profiles"
            ).fetchone()[0]
        self.assertIsNone(source)

    @staticmethod
    def _create_legacy_database(
        database: Path,
        observations: list[tuple[str, str, list[float]]],
        profiles: list[tuple[str, list[float]]],
    ) -> None:
        with closing(sqlite3.connect(database)) as connection:
            with connection:
                connection.execute(
                    """CREATE TABLE speaker_assignments (
                    meeting_id TEXT NOT NULL, manifest_revision INTEGER NOT NULL,
                    speaker_id TEXT NOT NULL, display_name TEXT NOT NULL,
                    confirmed_at TEXT NOT NULL,
                    PRIMARY KEY(meeting_id, manifest_revision, speaker_id))"""
                )
                connection.execute(
                    """CREATE TABLE observed_voices (
                    meeting_id TEXT NOT NULL, manifest_revision INTEGER NOT NULL,
                    speaker_id TEXT NOT NULL, embedding_json TEXT NOT NULL,
                    model_id TEXT NOT NULL, dimension INTEGER NOT NULL,
                    PRIMARY KEY(meeting_id, manifest_revision, speaker_id))"""
                )
                connection.execute(
                    """CREATE TABLE voice_profiles (
                    display_name TEXT NOT NULL, embedding_json TEXT NOT NULL,
                    confirmed_at TEXT NOT NULL, model_id TEXT NOT NULL,
                    dimension INTEGER NOT NULL)"""
                )
                for meeting_id, name, embedding in observations:
                    connection.execute(
                        "INSERT INTO speaker_assignments VALUES (?, 1, ?, ?, ?)",
                        (meeting_id, "microphone:SPEAKER_00", name, "2026-09-17T00:00:00Z"),
                    )
                    connection.execute(
                        "INSERT INTO observed_voices VALUES (?, 1, ?, ?, ?, ?)",
                        (
                            meeting_id,
                            "microphone:SPEAKER_00",
                            json.dumps(embedding),
                            "model@1",
                            len(embedding),
                        ),
                    )
                for name, embedding in profiles:
                    connection.execute(
                        "INSERT INTO voice_profiles VALUES (?, ?, ?, ?, ?)",
                        (
                            name,
                            json.dumps(embedding),
                            "2026-09-17T00:00:00Z",
                            "model@1",
                            len(embedding),
                        ),
                    )


if __name__ == "__main__":
    unittest.main()
