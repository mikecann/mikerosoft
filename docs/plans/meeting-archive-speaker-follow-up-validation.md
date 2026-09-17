# Speaker follow-up validation, 17 September 2026

The title prompt now leads to a processing window. Closing processing allows
it to continue, and completed speaker analysis opens review. Outstanding
speaker names remain visible in the menu bar and meeting library after Later
or window dismissal. Complete is disabled until every speaker is confirmed.

## Automated checks

- 108 Python worker tests passed, including read-only pending-speaker counts,
  missing/corrupt/stale transcript handling, and confirmed assignments.
- The offline Swift production-seam and recording state-machine scenarios
  passed, including camera start/stop, skip, recovery, and overlap cases.
- The follow-up scenarios passed: processing/unknown/offline states, exact
  revision matching, deferred attention during a call or ambiguous camera
  state, one-time presentation, dismissal, and restart persistence.
- The async speaker-review scenarios passed: loaded confirmed names, editing,
  failed confirmation, zero speakers, and preserving newer edits while an
  earlier confirmation is in flight.
- SwiftPM build and staged app signature verification passed. Full XCTest
  remains unavailable in the current local Xcode/Command Line Tools setup;
  the standalone scenario runners execute production Swift code instead.

## Runtime checks

The worker status command on Bruce reports the real latest solo Zoom recording
(`27239526-e960-422a-8dec-659eb298d5bf`, revision 2) as processed with one total
speaker and one unconfirmed speaker. No speaker identity was submitted.

The updated signed app automatically opened its real speaker-review window.
The transcript excerpts, empty name field, disabled Confirm/Complete buttons,
and Later action were checked through native accessibility and a screenshot.
After Later, both existing test recordings remained labelled as needing one
speaker name in the library. The updated app was then registered from its own
Settings and verified running as exactly one managed background process.

An isolated native UI harness used a read-only SQLite backup in a disposable
temporary directory, with capture, recovery, uploading, and device polling
disabled. It displayed the actual production processing view with a simulated
leased job. After Continue in background closed that window, a real read-only
Bruce status refresh brought the actual speaker-review window forward again.
Later closed review without confirming a name. The harness was then quit.

The processing-to-review UI transition was simulated; this update did not
record another live meeting or repeat transcription. The earlier real Zoom
capture/processing smoke evidence remains separate. macOS notification access
is still denied, so attention uses the review window and menu-bar indicator.

## Repeating the UI check

Build with `bash tools/meeting-archive/verification/run-follow-up-ui-harness.sh
--build`, then run the same script with `--prepare`. Open the resulting
`/private/tmp/Meeting Archive UI Verification.app` through the native UI. Its
isolated data path is embedded and signed before launch. Choose Continue in
background, then Finish simulated processing. Do not submit a speaker identity
while using real archive metadata unless the user has provided that identity.
