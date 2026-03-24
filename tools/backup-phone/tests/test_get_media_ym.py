import importlib.util
import unittest
from datetime import datetime
from pathlib import Path

_root = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("get_media_ym", _root / "get_media_ym.py")
_mod = importlib.util.module_from_spec(_spec)
assert _spec.loader
_spec.loader.exec_module(_mod)


class TestParseExifDatetime(unittest.TestCase):
    def test_valid(self) -> None:
        dt = _mod._parse_exif_datetime("2024:03:15 10:30:45")
        assert dt == datetime(2024, 3, 15, 10, 30, 45)

    def test_invalid(self) -> None:
        self.assertIsNone(_mod._parse_exif_datetime("not a date"))
        self.assertIsNone(_mod._parse_exif_datetime(""))


class TestMediaYearMonthFolder(unittest.TestCase):
    def test_nonexistent_file(self) -> None:
        self.assertIsNone(_mod.media_year_month_folder(_root / "does-not-exist-xyz.bin"))


if __name__ == "__main__":
    unittest.main()
