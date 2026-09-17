# Meeting Archive worker foundation

This stdlib-only Python package verifies finalized meeting bundles, accepts
them into permanent storage without overwriting archive inputs, and durably
queues one heavy processing job at a time.

Run it from the repository root with the worker directory on `PYTHONPATH`:

```sh
PYTHONPATH=tools/meeting-archive/worker python3 -m meeting_archive_worker verify INCOMING_DIR
PYTHONPATH=tools/meeting-archive/worker python3 -m meeting_archive_worker accept --incoming INCOMING_DIR --archive-root ARCHIVE_ROOT --db WORKER_DB --manifest-sha256 RAW_MANIFEST_SHA256 --validate-media
PYTHONPATH=tools/meeting-archive/worker python3 -m meeting_archive_worker status --db WORKER_DB --meeting-id UUID
PYTHONPATH=tools/meeting-archive/worker python3 -m meeting_archive_worker retry --db WORKER_DB --meeting-id UUID
PYTHONPATH=tools/meeting-archive/worker python3 -m meeting_archive_worker process-ready --archive-root ARCHIVE_ROOT --db WORKER_DB --processor package.module:function
PYTHONPATH=tools/meeting-archive/worker python3 -m meeting_archive_worker review-speakers --archive-dir MEETING_DIR --revision 1 --db WORKER_DB
PYTHONPATH=tools/meeting-archive/worker python3 -m meeting_archive_worker identify --meeting-id UUID --revision 1 --speaker-id incoming:SPEAKER_00 --name "Name" --db WORKER_DB
PYTHONPATH=tools/meeting-archive/worker python3 -m meeting_archive_worker.service --db WORKER_DB
```

Every command writes one compact JSON object. Validation and contract errors
use exit code 2. A processor failure uses exit code 1 and records either a
retry with bounded exponential backoff or a visible permanent failure when the
adapter raises `meeting_archive_worker.cli.PermanentProcessingError`.

Production transfers pass `--validate-media`. The worker probes every declared
audio/video file in permanent storage for the expected stream and a positive
duration, checks that the media covers the claimed meeting duration, fully
decodes each stream, and re-verifies its manifest hash before it commits the
cleanup acknowledgement. The acknowledgement then includes a
`media_validation` audit object. Omitting the flag is intended for lightweight
fixture tests and does not add that object.

`ARCHIVE_ROOT` and the parent directory of `WORKER_DB` must already exist. The
service deliberately will not create the configured volume root, so a missing
external volume cannot turn into a lookalike directory on the startup disk.
Installation must verify the expected mounted volume before creating them.

The processor callable receives `(archive_directory: Path, job: Job)`. Model
packages stay outside this core so importing and testing it never loads a
transcription model. `TranscriptProcessor` provides the separate-channel merge
seam: it preserves `microphone` or `incoming` as `channel_origin`, independently
of any optional diarization speaker label.

The optional Bruce adapter is `meeting_archive_worker.processor:process`.
It imports faster-whisper and pyannote only when a job runs. Configure `HF_HOME`
on CannMedia and supply `HF_TOKEN` to enable diarization. With no token it
refuses to start model work and leaves the job retryable. The explicit
`MEETING_ARCHIVE_ALLOW_TRANSCRIPTION_WITHOUT_DIARIZATION=1` override exists for
synthetic testing and records diarization as disabled in provenance. The setup
smoke test is
`python -c 'import faster_whisper, pyannote.audio'`; real model success still
requires a representative fixture benchmark on Bruce.

The service keeps media processing and Notion publication in separate durable
SQLite states. A Notion outage retries publication with backoff and does not
run transcription or playback generation again. Credentials are read only from
`MEETING_ARCHIVE_NOTION_TOKEN`, `MEETING_ARCHIVE_NOTION_DATA_SOURCE`, and
`HF_TOKEN`; the worker never includes them in status or result JSON.
The service accepts `--db WORKER_DB` and optional `--poll-seconds SECONDS`. It
holds one process lock for that database, while both media processing and
publication also use durable leases for crash recovery.

Whisper defaults to two CPU threads and enables its voice-activity filter to
avoid inventing text across long silent spans. Diarization decodes through
ffmpeg into a disk-backed 16 kHz mono buffer so pyannote does not depend on
torchcodec's FFmpeg ABI support. The float waveform has a default 1.5 GiB
memory budget, configurable with
`MEETING_ARCHIVE_MAX_DIARIZATION_MEMORY_BYTES`. The worker never truncates a
long track: if it exceeds that budget, the complete source stays queued with
an actionable error. Chunked diarization with cross-chunk speaker matching is
required before unusually long recordings can run inside a smaller budget.

`status` accepts up to 100 repeated `--meeting-id` filters. Its processing jobs,
counts, and nested publication jobs are scoped to those meetings, which keeps
the app response bounded as the archive grows. Omitting the filter retains the
operator-facing full queue response. The `publication` object includes its
scoped aggregate `phase`, `last_error`, counts, and durable job details.

`retry --meeting-id UUID` is an idempotent operator action. It releases only a
processing job in `retry_wait` or `permanent_failure`, or an errored publication
job in `retry_wait`. It never takes a live lease and never moves succeeded
processing back to ready, so a Notion retry cannot retranscribe the meeting.
The JSON response identifies the processing and optional publication stage and
whether this call changed either queue.

Confirming a speaker name rewrites
the JSON and Markdown views with fsync plus atomic replacement, then requests a
fresh idempotent Notion publication without retranscribing media.

`review-speakers` returns nullable confirmed, automatic, and tentative names,
cosine similarity and separation values, whether an embedding exists, three timestamped excerpts
per diarized speaker, an optional absolute playback path, and normalized
calendar candidate objects. `identify` uses the saved observation automatically
and enrolls it only after that explicit confirmation.

Strong matches retain the 0.82 cosine / 0.08 runner-up margin gate and require
an explicitly confirmed source meeting. Review-only tentative suggestions use
0.65 / 0.08 and at least two distinct confirmed source meetings. These are
engineering defaults, not calibrated probabilities or a completed human
recognition accuracy benchmark. Matching excludes the current meeting across
all revisions. Profile provenance is migrated from unambiguous existing
assignments and observations; repeated confirmations update one source profile.

Only strong matches are written as transcript names, with `name_source` set to
`voice_match`. Explicit corrections use `confirmed`. Tentative matches stay in
the review evidence. The service retries durable speaker refresh requests so
interrupted transcript or Notion updates recover without retranscribing or
enrolling predictions. Per-meeting locks serialize review/confirmation writes.

`vision/build.sh` builds the local Apple Vision OCR helper during Bruce setup.
Video analysis samples at most 12 frames, three per speaker, within a shared
20-second budget. It compares text only against previously confirmed full names
and calendar attendee names. `video_label` and `active_speaker_label` evidence
is cached separately with video/turn/candidate provenance, never used to lower
voice thresholds or automatically name a speaker. Missing OCR tools and failed
frame reads do not block transcription or archiving. See [vision/README.md](vision/README.md).

## Bruce background service

Bruce uses the fixed external root `/Volumes/CannMedia/MeetingArchive`. The
runtime wrapper refuses to start unless `/Volumes/CannMedia` reports the exact
volume UUID `5CCB1D81-5A98-4C4A-9E2C-3E10B23F1B46`. It performs that check
before Python can open `worker.sqlite`, and it never creates a replacement path
on the internal disk.

The deployment paths are fixed:

- worker source: `/Volumes/CannMedia/MeetingArchive/runtime/worker`
- Python environment: `/Volumes/CannMedia/MeetingArchive/runtime/venv`
- Hugging Face models: `/Volumes/CannMedia/MeetingArchive/runtime/models`
- other caches: `/Volumes/CannMedia/MeetingArchive/runtime/cache`
- decode scratch space: `/Volumes/CannMedia/MeetingArchive/runtime/tmp`
- queue database: `/Volumes/CannMedia/MeetingArchive/worker.sqlite`

Stage the per-user LaunchAgent without loading it:

```sh
bash /Volumes/CannMedia/MeetingArchive/runtime/worker/install-service-bruce.sh
```

Staging is the default so the generated plist can be reviewed first. Starting
or restarting the service always requires the explicit flag:

```sh
bash /Volumes/CannMedia/MeetingArchive/runtime/worker/install-service-bruce.sh --enable
```

The LaunchAgent runs one low-priority background service. The wrapper constrains
Whisper, PyTorch, OpenMP, and MKL to two CPU threads, disables model telemetry,
sets the virtual-environment and Homebrew system-tool path explicitly, and
redirects `TMPDIR`, `TMP`, `TEMP`, model data, caches, and decode scratch space
to CannMedia. It explicitly removes the synthetic-test transcription bypass
from its environment. The worker's own process lock and SQLite leases reject a
second active worker. Niceness is applied by the wrapper so direct invocation
has the same low-priority behavior as LaunchAgent invocation.

Bruce's login Keychain is locked for unattended SSH work. The launcher instead
loads `/Volumes/CannMedia/MeetingArchive/runtime/secrets/credentials.json`
from the encrypted archive volume. The directory must be owned by the worker
user with mode `0700`; the regular file must have mode `0600` and contain the
approved `huggingFaceToken` and `notionToken` JSON fields. Symlinks, shared
permissions, unexpected fields, and malformed data are rejected. Values only
enter the worker's process environment; they are never printed, placed in
command arguments, or included in the plist/source repository. Provisioning
requires the user's authorization and occurs separately over encrypted SSH.

The scripts never create or copy credentials. If credentials are unavailable,
the service still starts; affected jobs remain in durable retry state and
`status` exposes the processing or publication error. Notion publication uses the
existing data source `fe4b72d1-b303-42ba-a812-3349655746c5` without changing
its schema.

Credentials are loaded once when the service process starts. After adding or
changing the protected credential file, restart explicitly with:

```sh
bash /Volumes/CannMedia/MeetingArchive/runtime/worker/install-service-bruce.sh --enable
```

Disable and unstage the service with:

```sh
bash /Volumes/CannMedia/MeetingArchive/runtime/worker/uninstall-service-bruce.sh
```

Disabling unloads the LaunchAgent and removes only its plist. It preserves the
archive, incoming data, SQLite queues, models, caches, worker source, and
the protected credential file. Any interrupted lease is recovered by the normal retry logic
when the service is explicitly enabled again.

## Private playback viewer

The optional playback viewer resolves canonical meeting UUIDs only through the
durable acceptance database and exposes the fixed generated playback and
transcript resources on localhost. Its production wrapper is locked to
`127.0.0.1:8765`, the verified CannMedia meetings root, four request threads,
and the Tailscale identity `mike.cann@gmail.com`. It receives no model or
publication credentials.

Installation stages an owner-only LaunchAgent by default. Starting the viewer
requires `--enable`, and Tailscale routing remains a separate explicit action.
The intended tailnet-only route is HTTPS port 10443 to localhost port 8765, so
Bruce's existing 443 and 8443 routes remain untouched. See
[`VIEWER.md`](VIEWER.md) for the route contract, security checks, isolated
fixture command, staging steps, and exact rollback commands.
