import pathlib
import sys
import unittest


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS_DIR))

from fast_final import merge_overlapping_transcripts


class FastFinalMergeTests(unittest.TestCase):
    def test_merges_a_clean_word_overlap(self):
        self.assertEqual(
            "we should ship this today because it is ready",
            merge_overlapping_transcripts(
                "we should ship this today",
                "this today because it is ready",
            ),
        )

    def test_matches_overlap_despite_punctuation_and_case(self):
        self.assertEqual(
            "I think this is right. But let's verify it",
            merge_overlapping_transcripts(
                "I think this is right.",
                "this is RIGHT, but let's verify it",
            ),
        )

    def test_uses_the_longest_overlap_when_words_repeat(self):
        self.assertEqual(
            "that is the thing that is difficult to explain",
            merge_overlapping_transcripts(
                "that is the thing that is difficult",
                "thing that is difficult to explain",
            ),
        )

    def test_returns_none_when_the_join_is_ambiguous(self):
        self.assertIsNone(
            merge_overlapping_transcripts(
                "I think we should probably leave it there",
                "well actually maybe we should change it",
            )
        )

    def test_returns_none_for_a_single_common_word_overlap(self):
        self.assertIsNone(
            merge_overlapping_transcripts(
                "I want to leave it as is",
                "is that really the best option",
            )
        )

    def test_accepts_a_tail_already_contained_in_the_base(self):
        self.assertEqual(
            "we can leave it exactly like that",
            merge_overlapping_transcripts(
                "we can leave it exactly like that",
                "exactly like that",
            ),
        )

    def test_empty_tail_keeps_the_precomputed_text(self):
        self.assertEqual(
            "the sentence was already complete",
            merge_overlapping_transcripts(
                "the sentence was already complete",
                "",
            ),
        )


if __name__ == "__main__":
    unittest.main()
