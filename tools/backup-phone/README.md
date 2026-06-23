![header](docs/header.webp)

# backup-phone

Backs up all photos and videos from an iPhone (over USB/MTP) to a flat folder on disk.


## Screenshots

![backup-phone screenshot](docs/ss1.png)


## Usage

```
backup-phone [-Destination <path>] [-DeviceName <name>] [-Yes]
```

| Parameter | Default | Description |
|---|---|---|
| `-Destination` | `D:\bak\photos` | Folder to copy files into |
| `-DeviceName` | `Apple iPhone` | MTP device name as shown in Explorer |
| `-Yes` | _(flag)_ | Skip the "press Enter when ready" prompt |

## What it does

- Connects to the phone via the Windows Shell COM MTP interface (no iTunes needed).
- Processes phone folders newest-first so recent photos arrive first.
- Prefixes each file with its source folder name to avoid collisions (e.g. `100APPLE_IMG_0001.JPG`).
- Converts HEIC files to WebP (90% quality, EXIF preserved) in the background while the next file copies.
- Skips files that are already present in the destination — safe to re-run.

## Dependencies

Python packages: `Pillow`, `pillow-heif` (installed by `deps.ps1`).

## Notes

- Unlock your phone and tap "Trust This Computer" before running.
- `.AAE` sidecar files (iOS edit metadata) are skipped automatically.