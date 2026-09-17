# Meeting Archive validation report

Date: 2026-09-17

This report separates bounded executable evidence from the live macOS and Bruce checks that still require the installed app, permissions, hardware, credentials, or the permanent archive. It does not treat a compile or fixture pass as proof of live meeting capture.

## Automated evidence

### Worker suite

Command:

```sh
python3 -m unittest discover -s tools/meeting-archive/worker_tests -v
```

During the filming pause, the executed worker suite reported **54 tests passed on Bruce**, in 0.671 seconds. This includes the source changes made during the filming pause; no tests ran on this Mac. The log is `/Volumes/CannMedia/MeetingArchive/logs/worker-validation-2026-09-17.txt`. Python 3.13 reported zero `ResourceWarning` entries after the explicit SQLite connection-lifecycle fix. The earlier run exposed one stale Whisper fixture and unclosed SQLite connections; both were corrected before the passing rerun.

The passing suite covers manifest and metadata validation, hash mismatch and path traversal rejection, symlink rejection, idempotent acceptance, a crash after manifest publication, partial archive resumption, durable queue leases and retry, one-heavy-job exclusion, media structural validation before cleanup acknowledgement, transcript timeline merging, playback muxing, speaker confirmation, and Notion retry/idempotency behaviour.

New cases also cover SQLite commit/rollback plus guaranteed closure, bounded Whisper threads and voice-activity filtering, rebuilding derived outputs from a durable transcript checkpoint, and publication refresh/status after speaker identification. The Bruce service wrapper and launch scripts passed `bash -n` on Bruce. They have not been enabled or exercised, and no credentials were accessed by this syntax check.

### Swift to Python to Swift contract

Command:

```sh
tools/meeting-archive/verification/run-contract-roundtrip.sh
```

Result: **passed**.

The fixture compiles the production `ModelCodec`, models, and manifest types directly with the Command Line Tools Swift compiler. Swift writes canonical `manifest.json` and metadata bytes; the Python worker verifies and accepts them into an isolated temporary archive and durable ready job; Swift then decodes and validates the returned acknowledgement, verified-file list, manifest revision, cleanup flag, and raw manifest digest. The fixed meeting ID was `7c3f6176-b12c-4b25-8e81-0dafb231f984` and the manifest digest matched on both sides.

This fixture deliberately uses small placeholder media payloads so it isolates the JSON and digest contract. The production transfer now passes `--validate-media`; structural media validation is covered separately by the worker tests and the live-transfer driver.

### Capture state transitions

Command:

```sh
tools/meeting-archive/verification/run-state-machine-scenarios.sh
```

Result: **passed**. The direct `swiftc` fixture executes the production state machine through camera-off during asynchronous startup, skip during startup, persisted skip state, restart suppression, overlapping supported sessions, and a rapid next session. In particular, a late `captureStarted` after camera-off or Skip emits the correct immediate stop effect instead of leaking a writer.

### Forced-exit writer recovery

Command:

```sh
tools/meeting-archive/verification/run-forced-exit-recovery.sh
```

Result: **passed outside the command sandbox**, where the macOS hardware HEVC encoder is available.

The fixture compiles the production `TrackWriter`, feeds six seconds of synthetic 1920 x 1080 video plus two independent PCM audio sources on one timeline, waits for full two-second fragments, and calls `_exit(0)` without `finish()`. `AVURLAsset` then recovered:

| Source | Start | Recoverable duration |
| --- | ---: | ---: |
| Meeting video | 0.000 s | 4.000 s |
| Microphone | 0.000 s | 4.137 s |
| Incoming audio | 0.000 s | 4.137 s |

The maximum recovered end-time difference was about 137 ms, inside the 250 ms target. FFmpeg successfully decoded and remuxed the three unfinished source containers. The run demonstrates readable fragments and a bounded loss of the active tail, about two seconds in this case. Preserve the recovered original fragments when creating a stable remux on Bruce. This does not prove sudden power-loss durability, filesystem flush behaviour, or live ScreenCaptureKit timing.

### Offline regression fixture on Bruce during filming

Command: `bash verification/run-offline-regressions.sh`, executed from Bruce's isolated `/Volumes/CannMedia/MeetingArchive/runtime/swift-validation` source snapshot.

Result: **passed**. The fixture compiles the actual core, capture coordinator, transfer, cleanup, spool, and timeline sources. It uses temporary fake files and a stub process runner. It neither launches the app nor accesses devices, credentials, real recordings, or the network.

The checks cover deferred capture through an unsafe view followed by exactly one safe start, stale stop rejection, retaining captured media on Skip, interrupted-start suppression, nested symlink escape refusal, acknowledgement identity validation, local cleanup resumed after an already-missing file, repeated cleanup, retention of raw proof and unmanifested files, and refusing a wrong archive-volume UUID before any write command.

The first run exposed a real retry bug: Foundation reported a missing file as `CocoaError.fileReadNoSuchFile` rather than `fileNoSuchFile`. Cleanup now accepts either missing-file error only in its explicit resumable-deletion path. The rerun passed. The log is `/Volumes/CannMedia/MeetingArchive/logs/swift-offline-regressions-2026-09-17.txt`. This executable fixture is separate from XCTest and does not establish live capture or real-media cleanup readiness.

### Production transfer driver

`tools/meeting-archive/verification/run-live-transfer.sh` compiles the actual core contract and `ArchiveTransfer` actor into a temporary executable. It accepts `LOCAL_BUNDLE HOST VALIDATION_ROOT`, invokes the same SSH, rsync, worker media validation, acknowledgement decoding, and local receipt path as the app, while allowing an isolated remote archive root. The driver compiled successfully. Its remote execution and results belong in the lead's Bruce end-to-end evidence.

## Durability review

The permanent archive path is conservative in the areas most likely to cause data loss. Swift hashes every finalized manifest file before transfer and rejects symlinks or paths outside the spool. Rsync does not use mirror or delete flags. Bruce copies inputs with exclusive creation, verifies hashes again, fsyncs files and directories, and commits the processing job and cleanup-safe acknowledgement in one SQLite transaction. Retries verify an existing archive instead of overwriting it. Local cleanup validates the acknowledgement against the exact local manifest and requires its full media-validation proof, preserves metadata, manifest and the original acknowledgement in the local index, re-hashes each local media file, and removes only explicit manifest media paths. Cleanup is additionally gated by `backupCoverageVerified`. The product does not wait for a separate per-file backup receipt. Real cleanup testing remains outstanding.

Durability checks and fixes during validation:

- The exact crash-after-manifest-write regression passes. A reviewer suspected a duplicate close; the owning agent could not reproduce it in the current source. No duplicate-close fix should be claimed without a corresponding diff.
- The worker gained full media probing/decoding before it can issue `cleanup_allowed`, and the production Swift transfer now supplies `--validate-media`. Before that wiring, hash-valid arbitrary bytes could receive a cleanup acknowledgement.
- Interrupted-capture recovery originally wrapped the entire spool-directory loop in one `do/catch`, allowing one damaged bundle to starve every later recovery. It now retains and reports that bundle while continuing per directory.
- Upload now verifies the exact CannMedia UUID and existing incoming/archive directories before it can create a staging directory or transfer bytes. The real Bruce directories returned the same filesystem ID and `Directory` type. Missing/wrong-volume rejection has offline fixture coverage; unplugging the drive during an active transfer remains untested.
- Capture finalization and late callbacks are now scoped to meeting IDs. A new camera session can wait for the previous writer to finish without losing its start request. Skip preserves the recorded portion for the normal naming/default-save flow.
- Cleanup checks the complete deletion set for intermediate symlinks, validates the persisted receipt identity and metadata hash, and preserves the raw media-validation proof. The fake-file regression fixture above passed; no real recording was deleted.

The recorder uses fragmented MOV/M4A containers rather than separate segment files. The forced-exit fixture gives useful evidence for process-crash recovery with roughly one fragment of tail loss, but the product should describe that measured behaviour accurately. It should not claim that every sample is crash-safe or that sudden power loss is proven.

## Toolchain boundary

The normal XCTest path on this Mac is unavailable because the host has not accepted the Xcode license. During filming, the latest package source was copied to an isolated directory on Bruce. Its Swift 6.2.3 Command Line Tools compiled the complete application successfully in 34.51 seconds, using two low-priority build jobs. The executable was never launched. The build log is `/Volumes/CannMedia/MeetingArchive/logs/swift-build-2026-09-17.txt`.

`swift test` was also attempted on Bruce and stopped with `no such module 'XCTest'`: its standalone Command Line Tools do not include that framework. This is a toolchain limitation, not a passing test run. Earlier direct `swiftc` fixtures executed the production pure types, transfer actor, timeline, and writer. No XCTest result should be reported until a usable full Xcode setup is available and the package tests actually run.

## Live Bruce evidence from the lead

Before the user began filming, the actual Swift transfer actor uploaded a generated two-channel, 17-second fixture to an isolated Bruce archive. A second upload returned the same meeting acknowledgement and queue job ID. The worker probed and fully decoded all three permanent media tracks before issuing the acknowledgement. The raw receipt is `/tmp/meeting-archive-e2e/acknowledgement.json`; the source fixture ID is `5927cee6-d4ec-42d0-a4db-21d919de226b`.

The isolated archive is `/Volumes/CannMedia/MeetingArchive/validation/meetings/2026/09/5927cee6-d4ec-42d0-a4db-21d919de226b`, using `validation/worker.sqlite`. Public Whisper `small.en` transcribed both generated voices correctly into eight timestamped turns, retaining incoming/microphone provenance and overlapping timelines. Speaker diarization was explicitly disabled for this isolated test because copying the existing credentials to Bruce awaits user approval. That result is marked `diarization_status: explicitly_disabled`, and it does not count as speaker identification validation.

The cold run, including model download, took 39.58 seconds. Maximum RSS was 1,318,518,784 bytes; peak memory footprint was 1,365,070,912 bytes. Playback contains H.264 video lasting 17.000 seconds and mixed AAC audio lasting 17.002 seconds, both starting at zero. This is a synthetic worker test, not a live ScreenCaptureKit test.

Bruce's volume UUID is `5CCB1D81-5A98-4C4A-9E2C-3E10B23F1B46`. Its current Backblaze configuration includes `/Volumes/CannMedia/`; inspected editable Mac rules and global file-type exclusions do not exclude this archive path or MOV/M4A/MP4/JSON/Markdown. No backup restore was performed. No local original media has been deleted.

## Filming pause

On 2026-09-17 the user asked that this Mac's audio/video setup and recording not be disturbed for approximately an hour. The lead stopped only the newly installed Meeting Archive process, verified by its exact executable path. Local media tests, builds, UI interactions, app restarts and permission changes were paused during filming. Michael subsequently confirmed filming was finished; the later section records resumed validation and the rebuilt app.

## Remaining live checks

The following rows require separate live evidence and remain untested by this report:

- Camera attribution and camera-off edges in Google Meet, Teams, and Slack. The bounded Zoom case passed below.
- Live exclusion of Record It and unrelated camera applications; Zoom preview/pre-join exclusion passed below.
- Meeting-window identity across Chrome tab changes, pop-outs, minimize, resize, Spaces, and permission loss.
- Remote speech intelligibility, shared-screen readability, system-default microphone changes, and extended speech while muted. Live Zoom window video and continuing microphone callbacks while muted passed below.
- Start, stop, quit, sleep, rapid sequential meeting, and overlapping-app races in the installed UI.
- One-hour resource use, audio continuity, encoder backpressure, and measured A/V drift.
- Held-out human speaker-recognition accuracy, speaker-review UI, and the actual private Notion-to-playback click path. Real Whisper/pyannote on synthetic voices, confirmed enrollment/reuse, and live Notion publication passed below.
- A restore from the Meeting Archive directory. Configuration-level backup coverage was inspected as recorded above.
- Local media cleanup after a complete real Bruce acknowledgement and durable processing handoff.
- Sudden power interruption during an active fragment or local cleanup.

The final smoke test must keep local cleanup disabled until valid source media, the isolated Bruce archive, processing queue, playback/transcript outputs, and backup coverage have each been verified from live state.


## Validation after filming finished, 2026-09-17

Michael explicitly released the filming pause and approved copying the existing Hugging Face and Notion credentials to Bruce. The original local Keychain entries were read without displaying token values. Bruce's login Keychain was verified locked (`-25308` on import), so the unattended worker uses `/Volumes/CannMedia/MeetingArchive/runtime/secrets/credentials.json`, on the encrypted archive volume, with owner-only directory/file permissions 0700/0600. Values crossed SSH through stdin only and were read-back verified without being printed. The new loader rejects unsafe ownership, permissions, symlinks, oversized/malformed input, and incomplete credentials. No original credentials were changed.

The Notion credential successfully read the existing data source and confirmed the unchanged schema. A live publication request then caught a real incompatibility: Notion rejects custom `meetingarchive://` rich-text links with HTTP 400. No test page was created by that failed request. A private HTTPS playback route is being evaluated before publication is claimed complete. The publisher now requires a credential-free HTTPS base URL and refreshes link properties when that route changes. API 2026-03-11 uses `in_trash`, not `archived`; a failing regression demonstrated the old request and the fix passes. Failed property updates now prevent a publication receipt instead of silently marking stale metadata successful.

The latest local Python suite passed **68 tests in 0.663 seconds**. This includes credential handling, bounded worker status and explicit retry, and the new Notion compatibility tests. Full Swift application build and stable bundle-signature verification passed under the separate Command Line Tools. The staged app's Library and Settings were inspected through native accessibility. The full Xcode license remains pending, so XCTest has not been claimed as executed.

The offline regression executable was expanded to compile and execute production `NativeCaptureLifecycle` and `WorkerStatus` logic. It passed cancellation at permission/startCapture boundaries, pre-activation sample rejection, immediate sample cutoff, stale meeting IDs, and published/processing/speaker-review/error/unknown status mapping. Additional asynchronous status/retry ordering verification is in progress.

### Real diarization and remembered speakers

Isolated fixture root: `/Volumes/CannMedia/MeetingArchive/validation/pyannote-e2e-fa66c215-a534-4ff1-ab9e-e4e9e4993b0c`. Evidence is saved in `evidence.json`, `review-a.json`, and `review-b.json` without credentials or voice vectors. Meeting A is `0a7eb22a-fe53-4d23-89ff-d038e7485bd3`; Meeting B is `bd6ad9e9-9fd0-4b5e-9f20-c2a20f925e28`.

Both jobs used real Whisper and pyannote 4.0.3 with diarization enabled and completed once. Four 256-dimensional observations were committed with model provenance. Explicitly identifying Meeting A's incoming voice as “Synthetic Alice” caused Meeting B to fill that name automatically at cosine 1.0. The unrelated microphone voice stayed unknown at 0.315. This uses repeated synthetic audio to prove the enrollment/reuse path; it is not a held-out accuracy benchmark for real human voices.

All original manifest files retained their declared size/hash. Both mixed playback files probed as H.264/AAC with 17.002 seconds of duration. A final processing call returned `no_ready_job`. No real recording or original media was deleted. The worker service remains disabled until the remaining integration checks pass.


### Native app setup and Zoom observations

`setup_mac.sh --with-launcher` completed with the Command Line Tools toolchain. The signed app is at `~/Applications/Meeting Archive.app` and the launcher at `~/.local/bin/meeting-archive`. The root installer was also exercised in an isolated temporary bin directory. The Library and new per-permission Settings screen were inspected. Microphone permission is granted; Accessibility and Screen/System Audio permission requests are pending. Notifications and calendar integration are not yet verified. Neither login service nor local media cleanup was enabled.

A fresh-ID Zoom test was opened without invitations. Its pre-join screen had a camera-on control but no joined Meeting menu. After joining, Zoom's toolbar disappeared from its window's AX tree when hidden. The global Meeting menu retained Stop video/Start video actions. The camera was turned off and the test meeting ended; Zoom was returned to its original closed state. Record It and system audio/video device settings were not changed.

The detector now has a passive, public-AX menu fallback restricted to one exact Zoom Meeting window. It never opens menus or activates Zoom. Fixtures prove on/off mapping, preview/home exclusion, ambiguous multiple windows, and conflicting evidence. The complete Swift package and executable offline regression harness pass after this change. Closed-menu accessibility in the installed recorder is still unverified until Accessibility permission is granted. This observation does not count as successful live recording.

### Live Notion publication

The synthetic Meeting A was published to the existing data source without schema changes: [Pyannote validation 1](https://app.notion.com/p/Pyannote-validation-1-3defd70ecfa0816c9f29d3eba1a49dfe). The API read-back confirmed 10 owned blocks and Synthetic Alice in both the speaker property and transcript. Repeating publication returned the same page. The HTTPS link properties were accepted. The private viewer route has not been activated, so the Notion-to-video click path remains pending.


### First real Zoom capture

A 149-second isolated Zoom call was recorded by the installed signed app after Accessibility, Screen/System Audio, and Microphone permissions were granted. The camera-on pre-join screen created no spool directory. The joined call created meeting `ec535fe1-f3a6-4263-9d27-6da11c05298b`, and the Library displayed “Recording meeting”. Recording continued after Zoom was muted and its toolbar/menu were closed. Camera-off stopped it. The end prompt was ignored; the Library progressed from “Saving shortly” to “Archived”. Zoom was unmuted again and the isolated call ended, returning Zoom to its prior closed state.

Bruce accepted all original files into `/Volumes/CannMedia/MeetingArchive/meetings/2026/09/ec535fe1-f3a6-4263-9d27-6da11c05298b`, after full decode/hash validation, as production queue job 1. Its manifest SHA-256 is `dee78df110941c37253d41b1649ea556fd551aa41899594a1c5dfae5edf0d608`. Local copies are still retained because cleanup is disabled. This proves the transfer and default-save path using actual device capture. It does not prove speech intelligibility from another participant or shared-screen readability.

The source video is HEVC, 1920 × 1080, with 2,215 frames. Its largest presentation-timestamp gap is 76.667 ms. Both audio tracks are 48 kHz, two-channel AAC. Captured callback counts were 13,970 microphone samples and 7,452 incoming samples; both ran through the end of the muted portion. Detailed ffprobe evidence is at `/Volumes/CannMedia/MeetingArchive/validation/live-zoom-20260917/media-evidence.json`.

The real-media check exposed two gaps hidden by earlier synthetic files: playback had copied H.264 input rather than proving HEVC-to-H.264 conversion, and AAC container start times differ from the authoritative capture clock. Both were corrected before processing the real job. Decoded video/audio timestamps now use the captured first-sample offsets once; AAC edit-list/container start times are not treated as capture time.

Calendar permission is now granted, but EventKit exposes only iCloud Home/Work, Birthdays, and Australian Holidays. The personal and Convex Google calendars are not available through this Mac integration yet. Notifications are denied; capture continues without them.

### Completed real processing and browser checks

The real Zoom job completed transcription, pyannote diarization, speaker observations, playback generation, and publication in 217.44 seconds on Bruce. It produced three microphone turns and no incoming turns, as expected for the one-participant fixture. This does not test intelligibility from a remote participant. The original four manifest files still match every declared hash and size.

Playback is H.264/yuv420p, 1920 × 1080, with stereo AAC at 48 kHz and a total duration of 149.281 seconds. A forced VideoToolbox re-encode using recipe v2 passed, then a second call reused the derivative without re-encoding. A synthetic flash/beep fixture separately proved the shared 1.300-second timeline within 100 ms after real HEVC/AAC encode/decode. Recipe provenance now binds source hashes and offsets; legacy derivatives without the matching recipe are rebuilt. Accepted sources cannot occupy the generated playback/transcript namespaces. Symlink/directory collision regressions preserve originals and external targets.

The production Notion page is [Meeting 17 Sep 2026 at 10:38 am](https://app.notion.com/p/Meeting-17-Sep-2026-at-10-38-am-3defd70ecfa08107a015c87f7aaba386). API read-back verified an active page, six blocks, and three timestamp links without visible internal markers. The Mac Library reached “Published to Notion · speaker review available”; its speaker sheet fetched the actual transcript and unknown-speaker samples. No identity was assigned by the agent.

The real private viewer was exercised through a temporary, fixture-scoped localhost proxy and SSH forward. It returned valid 206 byte ranges and rejected a direct request without identity. CUA verified H.264 decoding, the complete 0–17.002-second seekable range, timestamp seeking, and repeated clicking of the same timestamp. The synthetic player was muted for those checks. All temporary processes were stopped, and Bruce's unrelated Uvicorn service on port 8766 was preserved. The production Tailscale route remains inactive pending approval, so the actual Notion-to-HTTPS click path is still unverified.

Evidence files are under `/Volumes/CannMedia/MeetingArchive/validation/live-zoom-20260917/`: `processing-result.json`, `processed-evidence.json`, `notion-evidence.json`, and `playback-recipe-evidence.json`.

### Final regression and cleanup checks

The complete worker suite ran on Bruce with Python 3.13.13: **100 tests, zero failures, zero errors, zero skips**. A forced garbage collection plus `sys.unraisablehook` recorded zero unraisable errors. Earlier unclosed SQLite fixture connections were fixed explicitly; the first warning-bearing run is not counted as clean. The final results/log are in `validation/current-worker-tests/final-test-result.json` and `final-test.log`.

The executable Swift production harness and CLT app build passed with the latest Zoom Help/menu detector. XCTest remains unavailable because the full Xcode license has not been accepted. No XCTest pass is claimed.

`verification/run-real-media-cleanup-verification.sh` passed against a disposable copy of the real, remotely acknowledged 17-second synthetic bundle. It checked hashes and full-decode proof, removed exactly three copied media files, retained metadata/manifest/raw acknowledgement and unrelated files, preserved exact index proof, and repeated cleanup successfully. The original fixture remained byte-for-byte unchanged. The product cleanup toggle stays off, and no real local recording was deleted.

### Startup validation and remaining permission

The Mac's signed app registered its login item successfully. A controlled quit and LaunchAgent start resulted in one `meeting-archive-app --background` process managed by launchd. An actual reboot remains untested.

Bruce's first unattended service attempt exposed a real platform restriction: `/bin/bash` could not read `runtime/worker/run-service-bruce.sh` on CannMedia and exited 126. Unified TCC logs confirmed `kTCCServiceSystemPolicyRemovableVolumes` with subject `/bin/bash`. The failed restart loop was stopped. This is distinct from the successful SSH processing proof; unattended Bruce processing is not ready until normal app-specific drive consent and a launched-service run have been verified. No privacy permissions were reset or bypassed.

The worker installer now retains startup diagnostics in a private 0700 directory and 0600 stderr log under `~/Library/Logs/Meeting Archive`, rotating one previous log during setup. Source/model/media paths remain on CannMedia. The [smoke-test checklist](meeting-archive-smoke-test.md) separates setup needs and user-only checks from completed automated evidence.

### Signed Bruce launcher staged

The reviewed native consent launcher was built on Bruce with Command Line Tools and installed at `/Users/bruce/Applications/Meeting Archive Worker.app`. Its configuration/bookmark/path tests, real child-shutdown test, Info.plist checks, AppKit compilation, strict signature verification, stable designated requirement, and macOS 15 minimum target passed. The three installer contract tests also passed after updating both service entry points to the signed launcher. Build output, module cache, and scratch files stayed on CannMedia; only the small app bundle lives on the internal disk.

The setup window was inspected on this Mac and closed without selecting a folder or starting any worker. The final wording directs the user to select the archive and close the window when ready. No local drive permission was granted. On Bruce, the worker LaunchAgent now names the signed executable with the fixed `--worker` argument. It is staged, unloaded, and explicitly disabled. The viewer service and Tailscale route remain inactive.

Bruce still requires Michael to open the app, select exactly `/Volumes/CannMedia/MeetingArchive`, approve normal macOS drive access if prompted, and close the window after “Access is ready”. Actual permission persistence, launchd startup, and clean bootout with no surviving child are not yet verified. No unattended-processing claim follows from the successful signed build. Credentials were already transferred with permission and need no further copy approval.

### Drive consent and managed startup verified

Michael completed the Bruce folder selection and closed the setup app. The signed launcher reused its saved bookmark without a new prompt. Enabling the per-user LaunchAgent produced one native launcher and one Python child, with the worker holding the exclusive service lock and an empty private stderr log. The existing processing and publication rows remained `succeeded`, each with one attempt and no error.

Controlled `launchctl bootout` removed both processes and released the lock. A fresh bootstrap restored one worker. Sending SIGTERM to that launcher exercised KeepAlive: a new launcher/child pair appeared, both old processes exited, and the replacement acquired the lock. An initial immediate lock assertion raced Python initialization; a subsequent bounded readiness check verified the same replacement child held the lock without another restart. This observation was a test timing issue, not a passing immediate-readiness assertion.

Evidence is `/Volumes/CannMedia/MeetingArchive/validation/managed-startup-20260917/result.json`. The service is enabled and running. This proves saved-consent reuse and process lifecycle, not a new media job consumed by launchd or an actual reboot. The next real smoke-test meeting will establish managed processing; the completed meeting was not requeued merely to manufacture that evidence. Screen Sharing was available but unnecessary for these checks. Record It and system device settings were untouched.

The final runtime review found that processing verified an archive internally without comparing it to the claimed queue job. A test-first fix now rejects a mismatched meeting ID, revision, or manifest hash before creating output directories or loading models. Existing valid checkpoint recovery remains model-free. Wrapper startup failures now reach the private stderr log as well as unified logging. The complete Python suite passed on Bruce's isolated validation mirror: **105 tests, zero failures, errors, skips, or unraisable errors**. Results are in `validation/worker-guard-20260917/result.json` and `test.log`.

The actual archived meeting's source files and identity were independently reverified. After checking that both queues were idle, the worker was stopped, the two reviewed runtime files were updated, and the service was started again. The deployed hashes match the tested mirror; one launcher and one Python child hold the service lock with an empty error log. The post-update result is appended to the managed-startup evidence. No meeting was reprocessed or republished during this check.
