# Meeting Archive: Fable review

Review obtained through the actual Claude CLI on 2026-09-17. This document preserves Fable's full response and separates the lead agent's assessment. No implementation or main-plan changes were made as part of this review.

## Provenance

- CLI: Claude Code 2.1.267, requested model alias `fable`, effort `high`.
- Review model reported by the CLI: `claude-fable-5-1`.
- Exit code: 0; result: success; one review turn; duration: 181 seconds.
- Input: the complete 385-line current plan, plus instructions for a critical read-only review.
- Reviewed plan SHA-256: `c4190aa9bfefeaec6702e3e8fb529d8242396696ae7c86bbd3eceef7623d09be`.
- Fable had no tool access. Its API statements and suggested workarounds are review hypotheses, not live verification.
- The original result JSON and submitted prompt are retained at `/tmp/meeting-archive-fable.wUEWXV` for this local session. The full review text is preserved below so it does not depend on those temporary files.

Invocation, with input/output redirections omitted:

```sh
claude -p --model fable --effort high --permission-mode dontAsk --tools '' --strict-mcp-config --mcp-config '{"mcpServers":{}}' --safe-mode --no-session-persistence --output-format json --max-budget-usd 5
```

## Lead agent assessment

I agree with Fable's central recommendation: prove camera attribution and meeting-window capture before parallelizing the larger build. The current plan already has those gates, but they need more explicit pass/fail criteria.

### Findings I would incorporate

1. Define per-app meeting identity, including camera settings previews, pre-join screens, active calls, and multiple Chrome tabs. A Chrome process name or a Meet URL alone does not distinguish a pre-join screen from a joined call. Record those states in the experiment before choosing a rule.
2. Treat browser tab changes and window minimization as first-milestone requirements. After Fable's review, I checked Apple's documentation: a single-window stream excludes child/pop-out windows, its audio is app-wide, and minimized-window video pauses. Verify these behaviours on the installed OS rather than assuming that a covered window and a minimized window behave alike. [Apple ScreenCaptureKit session](https://developer.apple.com/videos/play/wwdc2022/10155/).
3. Do not assume a Chrome capture extension makes recording unattended. Google's documented tabCapture API requires user invocation and changes tab-audio playback unless it is routed back. A state-reporting extension plus native window capture is a different design and still has tab-change/minimization problems to prove. [Chrome tabCapture API](https://developer.chrome.com/docs/extensions/reference/api/tabCapture).
4. Specify actual timestamp conversion for the selected capture APIs, clock drift correction, and separate-track versus mixed transcription. Validate overlapping local/remote speech, speaker playback echo in the microphone, reconnects, and a long-session alignment fixture. Fable's suggestion to diarize only the incoming track is too broad: the local room may have multiple speakers. Preserve channel provenance without equating a channel with a named person.
5. Verify that the new archive directory is covered by Bruce's backup before enabling routine local cleanup. Keep Michael's settled policy of deleting local copies after complete remote verification and durable processing handoff; do not silently introduce a per-recording wait for a backup acknowledgement.
6. Add an explicit permission-loss/reauthorization experiment and a sustained local-spool free-space test. An unavailable capture source must produce an accurate status, never a false success notification.
7. Prove one complete capture-to-Bruce-to-transcript-to-Notion-to-private-playback run before the broad UI and integration work is distributed. Meet and Zoom are sensible first representatives; Teams and Slack remain required before overall completion.

### Findings I would not adopt as written

- Do not keep capturing for several seconds after a deliberate camera-off. Michael explicitly chose camera-off as the end. Device-notification noise can be filtered, but deliberate stop semantics must stay intact; gaps and camera-switch events need evidence-based handling.
- Do not drop remembered-speaker matching from the agreed deliverable. It can follow basic capture within the build sequence, while retaining the requested final feature and accuracy tests.
- Do not assume two audio tracks mean only two people, eliminate local-room diarization by default, or rely on a simple clap alone to establish alignment across differently delayed call audio. Use a controlled timestamped audiovisual fixture through each capture path.
- Do not replace resilient Notion updates with blind delete-and-rewrite. A managed transcript section may simplify the implementation, but it still needs recoverability after partial writes and must preserve manual notes.
- Do not accept an arbitrary interval of unrelated browser frames as the default. Measure the real capture race and identify a route that preserves the intended meeting-only scope. If it requires a workflow compromise, bring back that specific choice with experimental evidence.
- Fragmented MP4, native deep links versus loopback links, and per-app adapters remain experiments. None is a verified drop-in fix from this review.

### Questions that do not need reopening now

Camera-off behaviour, save-by-default, continuous microphone capture through mute, Bruce retention, and verified local-copy cleanup are already settled. Short clips follow save-by-default. The calendar connection route is a setup check before it is a user decision. A manual delete action for accepted archives is outside the agreed version-one scope. Whether a supported app's pre-join camera screen counts as a meeting is a small remaining boundary to document during the feasibility work; it need not block running the diagnostic experiment.

The review does not authorize or start implementation. Main plan remains unchanged so the recommendations are reviewable.

## Full Fable response, preserved verbatim

Reviewing the plan as written, with no tools run and no changes made.

## Verdict

The plan is careful and its intent is right, but it is not ready for full implementation. It is ready for a narrow feasibility spike. Two questions decide whether an unattended recorder is achievable at all, and the plan defers both to Gate A and Gate B without defining what a passing answer looks like. The first is how a meeting is attributed to an app when macOS offers no public list of camera consumers. The second is whether Google Meet in Chrome can be captured and followed at all, since window capture is not tab capture. Everything downstream is sound but much larger than the first version needs. I recommend running the spike on Meet and Zoom only, settling the attribution rule, then implementing a reduced milestone before dispatching parallel agents.

## Findings

Proven issues in the written design come first, then platform hypotheses that need specific experiments.

**1. The start predicate is underspecified and cannot work at process level for Chrome.** Affects Section 1, Gate A, P20. Section 1 defines the trigger as "camera use by a supported application", but a Chrome camera-test page, a Meet green-room page before joining, and a live Meet call are all the same process. Zoom's settings preview and pre-join dialog also hold the camera. So "camera in use by Zoom" would record a preview, and the exclusion list cannot be app-based. Failure scenario: Michael opens Meet's landing page to check his hair, cancels, and a fifteen-second empty recording is auto-saved permanently, transcribed, and published. Recommended change: define the trigger as a conjunction. Camera is in use, and a positively identified meeting surface exists for that app, with a stated per-app surface rule such as a Chrome tab whose URL is a Meet meeting path, or a Zoom window titled as a meeting. Treat A07 as required for Chrome, not optional. Acceptance test: with a Meet green-room tab open and camera on, nothing records. Joining the call starts recording within the latency target. A Zoom preview alone never records.

**2. No debounce policy for camera-signal flaps under the "no grace period" default.** Affects Section 1 defaults, Gate A, P12. Switching cameras, enabling a virtual background, plugging a USB hub, or sleep and wake can release and reacquire the device within a second. The plan stops on the first confirmed off and starts a new recording on the next on, so one meeting becomes several files, the naming prompt fires mid-call, and the seconds between are lost. This is compatible with Michael's requirement, since on and off still control recording. Recommended change: separate signal debouncing from session semantics. Keep capturing into a new segment during a short window, on the order of a few seconds, and only finalize if the off state holds. Mark any gap in the manifest. Acceptance test: in Zoom, switch camera and toggle a virtual background during a call. Exactly one recording results with any gap marked. A deliberate off held for longer than the window ends the session.

**3. Meet in Chrome exposes unrelated browsing unless tab identity is tracked continuously.** Affects Gate B07, P21, P26. Window capture follows the Chrome window. If Michael switches tabs in that window, the archive records his email until something notices. The plan says to mark a gap, but never says what signal detects the tab switch. Recommended change: choose the Chrome tab-state source now. The candidates are Chrome's Apple Events scripting interface, which adds an Automation permission and may be disabled by policy, or an extension. Poll or subscribe to the active tab and drop video frames whenever the active tab is not the meeting. State the worst-case exposure window in the acceptance criteria. Acceptance test: during a Meet call, switch to another tab for ten seconds and back. The recording contains no frames from the other tab beyond the stated lag, and the gap is logged.

**4. Local-copy cleanup is gated on a single unbacked disk.** Affects Section 4 transfer, Section 5, P37, P64. Local copies are deleted once Bruce acknowledges the manifest on CannMedia. Backup coverage of that directory is unverified, and the plan only says to check it in Phase 6. Between local deletion and the first backup run, one disk failure loses the meeting permanently. Recommended change: define "verified in the permanent archive" explicitly. Either gate cleanup on a second copy, or state that the user accepts single-disk exposure until backup runs. This is a user decision, listed below. Acceptance test: simulate a missing backup target and confirm cleanup does not proceed, or confirm the documented acceptance of the exposure.

**5. Clock domains for the three tracks are not defined.** Affects Section 4 journal, Section 5 drift target, P22, P23. The microphone runs on the audio device's sample clock, incoming audio and video arrive from ScreenCaptureKit on host time, and the plan says only "common monotonic timing". A USB microphone can drift by tens of milliseconds an hour relative to host time. Transcript timestamps feed seeking, so drift produces wrong seek positions on long meetings. Recommended change: stamp every buffer with host time in the manifest, and have Bruce align the tracks by those stamps, resampling if needed. Acceptance test: a one-hour capture with a clap at start and end shows both audio tracks and the video aligned within the drift target at the end.

**6. Transcription input strategy is undecided, and the two-track split is an unexploited simplification.** Affects Section 4 worker and speaker identification, P34, P40. The plan says transcripts come from "the preserved audio tracks" but not whether it transcribes the mix or each track. Incoming audio from ScreenCaptureKit contains no local microphone signal, so the microphone track is local room speech and the incoming track is remote speech. Transcribing them separately and merging by time gives local-versus-remote attribution for free, and diarization only needs to run on the incoming track. Recommended change: decide this now, and prefer per-track transcription with timeline merge. Acceptance test: overlapping speech from Michael and a remote participant produces two correctly attributed turns rather than one garbled turn.

**7. Speaker identity and Notion revision handling are overbuilt for version one.** Affects Section 4, Phase 4, P55. Calibrated cross-meeting voice matching with held-out evaluation, diarization split and merge UI, and an incremental Notion block map are each substantial projects. Version one gets almost all of the value from within-meeting diarization, calendar-attendee suggestions, manual naming, and rewriting a managed transcript section in Notion under a marker. Recommended change: keep the data model for voice profiles and provenance, but defer automatic cross-meeting matching and diarization repair to a second milestone. Replace the block map with delete-and-rewrite of the managed section. Acceptance test for the interim: correcting a name updates the same Notion page and preserves manual notes outside the managed section.

**8. Auto-accept plus permanent retention leaves no privacy lever after twenty seconds.** Affects Section 1 defaults, Section 4 save prompt. Skip only works if Michael reacts during the call. A personal call on Zoom that he forgets about is archived permanently and processed. The plan says Bruce has no automatic deletion workflow, which is correct, but it never states whether a deliberate manual delete exists. This is not a contradiction with the requirements. It is a decision the plan has not recorded. Listed below.

**9. The segment writer may be more complex than needed.** Affects Section 4 journal, P23. Independently finalized multi-file segments plus tail recovery is one option. A single fragmented MP4 per track with a short fragment interval gives crash tolerance from the container itself, with one file per track and simpler resumable upload by byte range. Engineering choice for the lead. Acceptance test either way: kill the process mid-recording and recover everything up to the last completed fragment.

Platform hypotheses needing specific experiments, none of which the plan should assume:

- **Screen-recording reauthorization prompts.** Recent macOS versions periodically ask the user to re-approve apps that capture the screen. An unattended login item could sit behind that prompt with capture silently blocked. Experiment: run the signed background app across the prompt cycle and confirm whether capture continues, fails loudly, or stalls. This belongs in Gate B, and it affects whether "unattended" is honest.
- **Whether camera-off in each app releases the device.** A06 covers apps that keep the device while sending black frames. If Chrome or Teams holds the device after camera-off, the settled stop rule needs the app adapter as the stop signal, not the device. Experiment: A02 with timestamps for every app.
- **App-scoped audio scope.** B05 already notes Chrome audio may include other tabs. Add Zoom's separate share window and Teams' pop-outs to that test.
- **Notion custom URL schemes.** C04 covers this. If Notion rejects a custom scheme, a local loopback HTTP link served by the app is the likely fallback. Test that too.
- **Bruce environment placement.** The startup volume has little free space. Confirm the Python environment and model downloads fit on CannMedia before installing anything, since torch and models can consume several gigabytes.

One consequence of a settled requirement is worth stating plainly, not as an objection. Any meeting where Michael keeps his camera off is never recorded, including long screen-share sessions where everyone switches video off. The smoke test bakes this in. He should confirm he understands this before the spike.

## Decisions, first milestone, and checklist additions

Genuine user decisions still open:

- **Backup gating for local cleanup.** Whether "verified archive" means one copy on CannMedia or a copy plus verified backup.
- **Manual deletion.** Whether a deliberate per-meeting delete exists on Bruce, or whether retention is truly irreversible.
- **Short recordings.** Whether a recording under some duration, such as a cancelled green room, is archived and published like any other, or archived but held from Notion until confirmed.
- **Chrome tab exposure.** Whether up to about a second of unrelated tab content per switch is acceptable, given the detection lag of any tab-follow mechanism.
- **Calendar route.** Whether Michael will add the Convex Google account to macOS Calendar so EventKit can serve both accounts without Workspace OAuth approval.

Engineering choices the lead can settle alone: debounce window, fragmented MP4 versus segments, per-track transcription, managed-section Notion rewriting, deep link fallback, and where the Bruce job store lives.

Proposed first milestone, before any parallel implementation:

1. Diagnostic observer for camera state plus per-app meeting-surface detection for Meet in Chrome and Zoom only. Produce the support matrix and settle the attribution rule.
2. Meet-window and Zoom-window capture at the proposed profile, with tab-follow for Chrome, the reauthorization prompt experiment, and a one-hour alignment test across all three tracks.
3. Bruce benchmark of the existing Whisper and pyannote path on a real two-speaker fixture, with the environment placed on CannMedia.
4. One end-to-end manual run: capture, auto-accept, upload with hash verification, transcript on Bruce, and a Notion page with a working private link. No cleanup, no voice profiles, no calendar.

Defer Teams and Slack, cross-meeting voice matching, diarization repair UI, historical import, playback video muxing, and the Notion block map. Keep their data model fields so nothing needs a migration later.

Additions to the task checklist:

- Gate A: define the per-app start predicate as camera-in-use plus identified meeting surface, and test Meet green room and Zoom preview as negative cases.
- Gate A: add a signal-flap experiment covering camera switch, virtual background, hub reconnection, and sleep and wake, and set the debounce window from measured results.
- Gate B: add the screen-recording reauthorization experiment for a background login item.
- Gate B: choose and test the Chrome tab-state source, and record the measured exposure lag.
- Phase 1: specify the clock domain and per-buffer host timestamps in the CaptureSegment contract.
- Phase 3: record the decision on backup gating in the cleanup acceptance rule, and move the backup verification from Phase 6 to before cleanup is enabled.
- Phase 3: decide the transcription input strategy and add an overlapping-speech fixture.
- Phase 5: replace the Notion block map with managed-section rewrite for version one.
- Phase 2: add a local disk free-space check to P02 and a low-space stop test that covers the spool specifically.
- Acceptance matrix: add rows for green-room negative case, signal flap during a call, reauthorization prompt pending, and one-hour three-track alignment.
