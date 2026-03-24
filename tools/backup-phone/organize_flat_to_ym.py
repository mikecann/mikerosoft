# Move every file in the root of a backup folder into YYYY/mmm subfolders (one Python process; fast for large trees).
#
#   python organize_flat_to_ym.py D:\bak\photos
#   python organize_flat_to_ym.py D:\bak\photos --dry-run
#   python organize_flat_to_ym.py D:\bak\photos --quiet

from __future__ import annotations

import argparse
import os
import shutil
import sys
from datetime import datetime
from pathlib import Path

from get_media_ym import IMAGE_EXTS_FOR_EXIF, _MONTHS, media_year_month_folder


def _ym_from_mtime(path: Path) -> str:
    ts = path.stat().st_mtime
    dt = datetime.fromtimestamp(ts)
    return f"{dt.year}{os.sep}{_MONTHS[dt.month - 1]}"


def _target_subdir(path: Path) -> str:
    ext = path.suffix.lower()
    if ext in IMAGE_EXTS_FOR_EXIF:
        ym = media_year_month_folder(path)
        if ym:
            return ym.replace("/", os.sep)
    return _ym_from_mtime(path)


def _unique_dest(dest: Path) -> Path:
    if not dest.exists():
        return dest
    stem, suf = dest.stem, dest.suffix
    parent = dest.parent
    n = 2
    while True:
        cand = parent / f"{stem}_{n}{suf}"
        if not cand.exists():
            return cand
        n += 1


def main() -> int:
    p = argparse.ArgumentParser(description="Organize flat backup root into YYYY/mmm folders.")
    p.add_argument("destination", type=Path, help="Backup root (only files directly here are moved)")
    p.add_argument("--dry-run", action="store_true", help="Print planned moves only")
    p.add_argument("--quiet", action="store_true", help="Less console output (summary only)")
    args = p.parse_args()
    root = args.destination.resolve()
    if not root.is_dir():
        print(f"Not a directory: {root}", file=sys.stderr)
        return 2

    files = [x for x in root.iterdir() if x.is_file()]
    print(f"Files at root: {len(files)}")
    moved = 0
    for path in files:
        if not path.is_file():
            continue
        try:
            sub = _target_subdir(path)
        except OSError as e:
            print(f"  SKIP (unreadable) {path.name}: {e}", file=sys.stderr)
            continue
        target_dir = root / sub
        target = target_dir / path.name
        target = _unique_dest(target)
        rel = target.relative_to(root)
        if args.dry_run:
            if not args.quiet:
                print(f"  {path.name} -> {rel}")
        else:
            target_dir.mkdir(parents=True, exist_ok=True)
            try:
                shutil.move(str(path), str(target))
            except FileNotFoundError:
                print(f"  SKIP (gone mid-run) {path.name}", file=sys.stderr)
                continue
            if not args.quiet:
                print(f"  {path.name} -> {sub}")
        moved += 1
        if args.quiet and moved % 500 == 0:
            print(f"  ... {moved} files ...")
    print(f"Done. Processed: {moved}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
