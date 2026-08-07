# Bruce photo backup

Backs up Michael's iCloud Photos library onto Bruce's directly attached
`CannMedia` APFS volume, then publishes ordinary network-accessible files as
space-efficient APFS clones.

This is machine-specific infrastructure, not a general mikerosoft tool. It is
kept in Git so Bruce can be rebuilt safely, but it is intentionally absent from
the public tool catalogue, website, and global PATH installer.

The script is deliberately bound to CannMedia's volume UUID. It refuses to run
against a different disk mounted at the same path, a non-APFS filesystem, or an
archive nested inside the managed Photos library.

## Layout

```text
/Volumes/CannMedia/
├── PhotoBackup/
│   └── Photos Library.photoslibrary
└── PhotoArchive/
    ├── 2025/01/...
    ├── 2026/08/...
    └── .photo-backup/reports/...
```

`PhotoArchive` is created only when `photo-backup export` is run. Existing
photo folders elsewhere, including anything on `ExternalBak`, are never used,
merged, cleaned up, or deleted.

## One-time Apple Photos setup on Bruce

1. Put the Photos library at
   `/Volumes/CannMedia/PhotoBackup/Photos Library.photoslibrary`.
2. Open it in Photos and choose **Use as System Photo Library**.
3. Enable iCloud Photos and choose **Download Originals to this Mac**.
4. Leave Photos running until it reports that it is synced with iCloud.

The library must remain on the drive attached directly to Bruce. Never open the
library itself over SMB.

## Install on Bruce

```bash
bash scripts/bruce/photo-backup/setup_mac.sh
```

The setup creates a private Python virtual environment under
`~/Library/Application Support/photo-backup` and installs the pinned
`osxphotos` dependency there. It does not install a global command.

## Commands

```bash
PHOTO_BACKUP="$HOME/Library/Application Support/photo-backup/source/photo-backup"
"$PHOTO_BACKUP" paths
"$PHOTO_BACKUP" status
"$PHOTO_BACKUP" export
"$PHOTO_BACKUP" auto
```

- `paths` verifies the mounted APFS volume identity and configured paths.
- `status` reports only aggregate asset counts and the number of originals
  still missing locally. It never prints photo filenames.
- `export` refuses to run until no originals are missing, then updates the
  network-accessible archive using originals, edited versions, Live Photo
  movies, RAW companions, XMP sidecars, and AAE adjustment files.
- `auto` uses a strict missing-originals check before the first archive. Once
  that check succeeds it records private initial-readiness evidence, performs
  the incremental export, and does not repeat the multi-hour scan every six
  hours. Later exports ask Photos to download any newly missing items and retry
  earlier export errors.

Normal `osxphotos` copies within the same APFS volume are copy-on-write clones,
so the library and archive initially share physical data blocks while remaining
independent files. The export intentionally does not use hardlinks, conversion,
or cleanup.

## Automatic operation

Install the user LaunchAgent on Bruce after running `setup_mac.sh`:

```bash
bash "$HOME/Library/Application Support/photo-backup/source/install-automation.sh"
```

It runs once at login and every six hours. Launchd will not overlap instances,
so a long first export can finish safely. Missing drives and genuine errors are
logged and retried on the next scheduled run; an incomplete initial iCloud
download is a normal successful wait state. The one-time initial readiness
query has a bounded two-hour window because loading a large external Photos
library can take well over 30 minutes.

Logs contain aggregate counts only:

```text
~/Library/Logs/photo-backup/automation.log
~/Library/Logs/photo-backup/automation-error.log
```

To remove the schedule without touching either library or archive:

```bash
bash "$HOME/Library/Application Support/photo-backup/source/uninstall-automation.sh"
```

## Tests

```bash
python3 -m unittest discover -s scripts/bruce/photo-backup/tests -v
```
