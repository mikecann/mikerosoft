# Prints YYYY/mmm (lowercase month) for backup folder layout from image EXIF or fails for fallback.
# Exit 0 if a date was determined from embedded metadata; exit 1 otherwise (caller uses file mtime).

from __future__ import annotations

import re
import sys
from datetime import datetime
from pathlib import Path

_MONTHS = ("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec")

# Extensions where we try embedded metadata first (same list as backup-phone.ps1).
IMAGE_EXTS_FOR_EXIF = frozenset(
    {".heic", ".heif", ".jpg", ".jpeg", ".jpe", ".png", ".webp", ".tif", ".tiff"}
)

_EXIF_DT_RE = re.compile(
    r"^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})$"
)


def _parse_exif_datetime(s: str) -> datetime | None:
    s = (s or "").strip()
    m = _EXIF_DT_RE.match(s)
    if not m:
        return None
    y, mo, d, h, mi, se = (int(x) for x in m.groups())
    try:
        return datetime(y, mo, d, h, mi, se)
    except ValueError:
        return None


def _exif_datetime_from_pillow(path: Path) -> datetime | None:
    try:
        from PIL import Image
    except ImportError:
        return None

    ext = path.suffix.lower()
    if ext == ".heic":
        try:
            import pillow_heif

            pillow_heif.register_heif_opener()
        except ImportError:
            return None

    try:
        with Image.open(path) as img:
            img.load()
            exif = img.getexif()
    except OSError:
        return None

    if not exif:
        return None

    # DateTimeOriginal, DateTimeDigitized, DateTime (IFD0)
    for tag in (36867, 36868, 306):
        raw = exif.get(tag)
        if raw:
            dt = _parse_exif_datetime(str(raw))
            if dt:
                return dt
    return None


def media_year_month_folder(path: Path) -> str | None:
    """Return 'YYYY/mmm' from embedded photo metadata, or None."""
    dt = _exif_datetime_from_pillow(path)
    if not dt:
        return None
    return f"{dt.year}/{_MONTHS[dt.month - 1]}"


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: get_media_ym.py <file>", file=sys.stderr)
        return 2
    p = Path(sys.argv[1])
    if not p.is_file():
        return 1
    ym = media_year_month_folder(p)
    if not ym:
        return 1
    print(ym, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
