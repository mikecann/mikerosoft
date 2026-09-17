# Meeting Archive

Meeting Archive is a native macOS menu-bar app for recording eligible meeting
windows with the microphone and incoming system audio, then keeping a local
library while a worker transfers verified bundles to Bruce for processing.

This tool is still in preview. A live Zoom test verified preview exclusion,
camera-triggered start/stop, continued microphone capture while Zoom was muted,
automatic saving when the end prompt was ignored, and verified transfer to
Bruce. Remote speech, shared-screen readability, and the broader app matrix
still need validation. Teams and Slack adapters are implemented but
live-unverified; Microsoft Teams is not installed on this Mac. Chrome automatic
capture is currently blocked pending a choice between a dedicated Meet window
and manual tab capture. Do not treat Chrome detection as working yet.

## Setup

After finishing any recording session, run this once from the repository root:

```sh
bash tools/meeting-archive/setup_mac.sh
```

The script builds and signs `~/Applications/Meeting Archive.app`. To also add
an idempotent `meeting-archive` symlink under `~/.local/bin`, use
`--with-launcher`. The root `install_mac.sh` can add that launcher too. This
setup script is intentionally separate from the Windows-only `install.ps1`.

Quit Meeting Archive from its menu before updating or rebuilding it, so an
active recording can finish cleanly. The setup script does not launch the app.

For an existing login item, disable startup before replacing the bundle. Open
the updated app normally, then use its Settings to disable and re-enable the
login item. During the September 17 update, command-line registration reported
success but macOS rejected the background launch; re-registering from the
running app restored it. Verify the managed process actually starts after the
foreground app quits. The Settings label alone is not a startup health check.

## First launch and privacy

Open the staged app yourself, then use Settings to request the permissions it
needs. macOS may require reopening the app after granting them:

- Accessibility, for meeting-window detection
- Screen & System Audio Recording, for the meeting window and incoming audio
- Microphone, which remains active even when the call is muted
- Notifications, for recording prompts
- Calendar access, after adding both the personal and Convex accounts in
  macOS Internet Accounts; select the calendars to use for title and speaker
  suggestions

The app can register or unregister its login item from Settings. The standalone
`uninstall-startup.sh` does the same startup-only unregister through Apple’s
documented `SMAppService` API and does not delete recordings or archive data.

## Bruce archive and cleanup

The configured Bruce archive path is `/Volumes/CannMedia/MeetingArchive` on
host `bruce`. Before enabling the cleanup toggle, verify that this exact
directory is covered by Bruce’s existing backup. A successful network transfer
alone is not evidence of backup coverage. Cleanup is allowed only after the
worker validates every declared media stream, rechecks the manifest, and saves
its durable processing job.

Transfers and Notion publication are retryable and recorded in durable local
state. A Notion outage does not repeat transcription or playback generation.
Existing files under the older `RecordedMeetings` location are left alone and
are not imported automatically yet.

Bruce uses a separate one-time drive permission for the
[worker launcher](worker/launcher/README.md). On this installation, that consent
is complete and the managed worker passed startup, clean shutdown, and automatic
restart. A solo recording completed processing and publication after a disk
priority correction and retry. A fresh call without corrective intervention
and an actual reboot remain untested.

## Review and current limits

The library supports playback, transcript access, and speaker review after a
processed archive is available. Calendar candidates are suggestions and need
manual confirmation. Keep the app’s minimal settings explicit: selected
calendars, Bruce host and archive path, and the backup-coverage confirmation.

Do not describe the app as production-ready until a representative live run has
verified recording, transfer, retries, and review on this Mac.

The catalog icon reuses the film icon from
[Mark James’s famfamfam silk set](https://www.famfamfam.com/lab/icons/silk/),
licensed under CC BY 2.5, as used by the existing Transcribe tool.
