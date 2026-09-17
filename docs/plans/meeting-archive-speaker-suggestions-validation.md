# Speaker suggestions and visible meeting names, 17 September 2026

The latest real Zoom recording did not offer Mike's name because its voice
matched the two earlier confirmed recordings at 0.720890 and 0.634363, below
the single 0.82 gate. Both confirmations and all three 256-dimensional
observations were present on Bruce. This was a recognition policy gap, not
lost persistence. Earlier validation had only proved repeated synthetic reuse.

## Changes

- Separate strong automatic names from tentative review suggestions. The
  tentative gate is 0.65 with a 0.08 competing-name margin and confirmations
  from at least two different meetings. The existing strong gate stays 0.82.
- Store profile source meeting/revision/speaker; migrate unambiguous legacy
  provenance, deduplicate reconfirmations, and exclude the current meeting
  from matching across all revisions. Predictions never enroll themselves.
- Show **Recognized**, **Possibly Mike Cann**, and **Confirmed** separately.
  Editing a recognised name requires confirmation. Similarity is no longer
  displayed as a confidence percentage.
- Read visible known full names with local Apple Vision OCR on Bruce. Sample
  at most 12 frames, three per speaker, within 20 seconds. Exact “Talking:” /
  “Speaking:” text is supporting evidence; gallery names remain candidates.
  No face matching or external model requests are involved.
- Atomically save explicit assignment, voice profile, and a durable refresh
  request. Serialize derived transcript writes per meeting. Retry transcript
  and publication updates after failure without repeating transcription.
- Build the OCR helper during Bruce installation; CLI fallback finds Homebrew
  ffmpeg even when SSH's PATH omits it.

## Validation

- 150 Python tests passed with `ResourceWarning` treated as an error. Includes
  realistic score boundaries, competing names, migration, repeat confirmation,
  current-meeting exclusion, failed writes, concurrent initialization, lost
  refresh races, bounded locks, OCR filtering, frame budgets, and unavailable
  helper behavior.
- Production SwiftPM build passed. Offline Swift scenarios passed for new and
  old worker responses, tentative/automatic/edited identities, evidence
  selection, invalid evidence, in-flight edits, and native playback teardown.
  Full XCTest remains unavailable with the current Command Line Tools setup.
- In an isolated Bruce database, removed only the latest recording's own
  confirmation/profile. The two previous real confirmations produced
  `suggested_name: Mike Cann`, score 0.7208904772079369, count 2, and no
  automatic/confirmed name. No new profile was enrolled.
- Actual OCR read the latest video's Zoom participant label at 5.970 and
  12.440 seconds. The first integration run caught an overly narrow label
  position filter caused by Zoom's bottom toolbar. Its exact bounding box is
  now a regression fixture; the window title remains rejected.
- CUA verified the production review view using that isolated real response:
  Mike Cann was prefilled, “Possibly Mike Cann” was visible, Complete was
  disabled, and both video-label timestamps appeared. The isolated client
  cannot write identities. Playback remained functional.
- CUA then verified the installed app against Bruce: the previously confirmed
  name remained Confirmed, visible-label evidence appeared, Complete was
  enabled, and the actual Play path opened the native player without crashing.
- Production migration retained exactly three voice profiles and passed
  SQLite integrity checks. No original audio/video or human assignment was
  deleted or re-enrolled during validation.
- Final runtime check: all three processing jobs and all three Notion
  publications succeeded, with no pending speaker refreshes. All 12 original
  manifest files passed size/hash verification. The five original voice-profile
  fields remained byte-for-byte equal to the pre-update SQLite backup.

## Deployment and evidence

Installed the signed app at `~/Applications/Meeting Archive.app` and worker
source/helper at `/Volumes/CannMedia/MeetingArchive/runtime/worker` on Bruce.
The macOS cached login identity needed unregister/register from the new GUI
build. The refreshed registration is `EF8EBA38-8CB2-43FD-BE05-489CE875AF7B`.
Both managed background services were restarted; the local recorder resumed
with no active capture interrupted.

Bruce evidence and rollback copies are under
`/Volumes/CannMedia/MeetingArchive/validation/speaker-suggestions-20260917`:
`review-final.json`, `production-review.json`, isolated database/media,
`before-worker.sqlite`, and `previous-worker`. The local previous signed app
is `/private/tmp/meeting-speaker-suggestion-fixtures-20260917/Previous Meeting Archive.app`.
Rollback must restore the compatible database and worker together; old code's
positional profile INSERT is incompatible with the expanded profile schema.

## Limits

The thresholds are engineering defaults, not calibrated probabilities. The
held-out real recording verifies this user's tentative suggestion path, not a
multi-person false-match rate. Automatic strong matching has deterministic
tests; broader human accuracy still needs a real multi-person test. Active
speaker text parsing has synthetic coverage; this solo recording only proves
participant-label OCR. Borders, faces, hidden participants, and names absent
from both prior confirmations and calendar candidates are not inferred.
