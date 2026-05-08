import unittest
import pathlib
import sys


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS_DIR))

from preview_format import wrap_preview


class PreviewFormatTests(unittest.TestCase):
    def test_wrap_preview_keeps_short_text_unchanged(self):
        self.assertEqual("hello there", wrap_preview("hello there"))

    def test_wrap_preview_wraps_to_two_lines(self):
        text = "one two three four five six seven eight"

        self.assertEqual(
            "one two three four\nfive six seven eight",
            wrap_preview(text, max_chars=20),
        )

    def test_wrap_preview_keeps_last_two_lines_with_leading_ellipsis(self):
        text = "one two three four five six seven eight nine ten"

        self.assertEqual(
            "\u2026five six seven eight\nnine ten",
            wrap_preview(text, max_chars=20),
        )


if __name__ == "__main__":
    unittest.main()
