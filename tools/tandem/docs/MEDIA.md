# Tandem media

How `TandemMedia` finds, describes and analyses the files in a video
folder. `ARCHITECTURE.md` is the contract; this is the detail behind it.

| File | What it does |
| --- | --- |
| `MediaScanner.swift` | Walks the folder, matches known items, roles |
| `MediaProbe.swift` | AVFoundation and ImageIO probing, frame timing, alpha |
| `Fingerprint.swift` | `size-mtime-sha256` identity |
| `TakePairing.swift` | record-it takes and the `.take.json` sidecar |
| `FolderWatcher.swift` | FSEvents, debounced, settled |
| `AnalysisCache.swift` | `.tandem/cache/<kind>/<key>/`, atomic commits, eviction |
| `JobScheduler.swift` | Priorities, limits, dedupe, preemption, cancellation |
| `MediaAnalysis.swift` | The public face: cached reads, requests, state |
| `AnalysisSettings.swift` | Per-kind settings and algorithm versions |
| `AudioJobs.swift`, `ThumbnailJob.swift`, `VideoIO.swift` (proxy), `TranscriptJob.swift`, `MatteJob.swift`, `IsolatedVoiceJob.swift` | The analyses |
| `EncodedMovieWriter.swift` | VideoToolbox into AVAssetWriter, exact frame times |
| `LoudnessMeter.swift`, `EncoderLock.swift` | BS.1770 meter (Accelerate), shared encoder lock |

## Scanning

`MediaScanner.scan(folder, known:)` returns every media file under the
folder (`scanReport` also says what's missing, renamed, unreadable, and
anything worth telling Mike).

- Skips hidden files and folders, `.tandem`, `exports`, `node_modules`,
  `.build`, `.git`, `*.wfp.dir` and package contents. Follows symlinks to
  files, never to folders.
- Media extensions: video `mov mp4 m4v`, audio `m4a mp3 wav aif aiff caf`,
  images `png jpg jpeg heic gif webp`.
- A known item keeps its ID when its path (relative to the folder) still
  exists, otherwise a new file with the same content (size and hash, not
  mtime) claims it as a rename. Its role, look and take survive.
- Files whose size and mtime match their stored fingerprint aren't probed
  again: the decision-models folder (295 files) scans in 0.43 s, then
  rescans in 0.01 s.
- A file that can't be read yet (a take still being written) is reported
  in `skipped`, not added; a known one stays as it was.
- Every stored value survives a JSON round trip unchanged (times are snapped
  to the 48 kHz grid), so `refreshMedia` doesn't see phantom changes.

Probing reads the sample table with `AVSampleCursor`, no decoding (43,376
frames in 3 ms). The frame rate is the mean of the regular frame intervals,
snapped to integer or 1000/1001 rates. A file is VFR when more than 0.5% of
its intervals (and at least three) are more than half a frame off the
usual one: the screen recording (6% irregular, gaps up to 20 s) is VFR,
the camera with 7 dropped frames isn't. Alpha: HEVC with alpha (`muxa` or
the ContainsAlphaChannel extension), 32-bit ProRes 4444, Animation and PNG,
or an image with an alpha channel. Sizes have the track rotation applied.

Roles, in order: `-camera` / `-screen` record-it names, the nearest folder
that says what it holds (`music`, `sfx`, `broll`, `graphics`,
`motion-graphics`, `stickers`...), words in the file name, then the kind.
Stray audio under 10 s is `sfx`, longer is `music`.

### Takes

`<base>-camera.<ext>` and `<base>-screen.<ext>` in the same folder share a
`takeID` (kept across scans). `takeOffset` is how long after the take's
first file each file starts:

1. From `<base>.take.json` if present:

   ```json
   { "version": 1,
     "files": [
       { "role": "camera", "file": "main-camera.mov", "startHostTime": 81234.512 },
       { "role": "screen", "file": "main-screen.mov", "startHostTime": 81234.498 } ] }
   ```

   `startHostTime` is `CMClockGetHostTimeClock` seconds at the file's first
   sample; `file` defaults to `<base>-<role>.mov`. record-it doesn't write
   this yet; its shared start gate means both files start on the same tick.
2. Otherwise from creation-date metadata. QuickTime stamps are whole
   seconds, so gaps up to a second between whole-second stamps count as 0.

Offsets that are negative, over 30 s or longer than the file are clamped
to 0 with a note in `ScanReport.notes`.

## Watching

`FolderWatcher(folder:debounce:settleTime:handler:)` reports
`Changes(added:changed:removed:)` as project-relative paths. Events are
debounced (1 s), and a file is only reported once its size and date haven't
changed for `settleTime` (2 s) by this Mac's clock, so a recording in
progress is reported once, at the end, and a file dated in the future
still settles. Folder events inside `.tandem` and `exports` never cause a
rescan, so analysis commits don't make the watcher walk the folder.
The app should call `refreshMedia()` (or `scanReport`) on each batch and then
`requestDefaults`, and `stop()` the watcher when the project closes (safe
from inside the handler too).

## Cache

`.tandem/cache/<kind>/<key>/` with
`key = sha256("<fingerprint>|<kind>|<algorithmVersion>|<settings JSON>")`.
Each entry holds `entry.json` (`CacheManifest`: kind, key, fingerprint,
version, settings, source path, bytes, files) and the result files. Jobs
write into `.tmp-<key>-<uuid>/` beside the entries and rename it into place
with the manifest already inside, so a lookup never sees half a result.
Temporaries whose newest file is over an hour old are removed on start.
Past the size limit (50 GB default) entries go least recently used first;
a lookup counts as a use (folder date, bumped at most once a minute). An
evicted entry is renamed away before it's deleted, so a lookup never sees
a manifest whose files are half gone.

Only the settings a kind uses go into its key (`AnalysisSettings.canonical`),
and bumping `AnalysisKind.algorithmVersion` rebuilds that kind.

## Jobs

`JobScheduler` runs one piece of work per ID (`<kind>-<key prefix>`, so two
copies of a file share a job):

- Order: priority (`interactive` > `timeline` > `background`), then kind
  (waveform, loudness, thumbnails, transcript, proxy, isolated voice,
  matte), then first come.
- Limits: two each of thumbnails, waveform and loudness, one of each other
  kind, one encoder job (proxy or matte) at a time, four in total.
- Asking again with a higher priority moves a job up.
- Long jobs call `checkpoint()` between frames: it throws on cancel, hands
  `EncoderLock.shared` to a waiting export (`.export` priority), and steps
  aside, keeping its state, when a more urgent job needs its slot (higher
  priority, or same priority and an earlier kind: a new take's proxy
  doesn't wait behind the last take's matte).
- Blocking work runs on GCD at the job's QoS (background for background
  jobs; proxies ran at the same 489 fps there), never on Swift's
  cooperative threads.
- Observers get the full status list, throttled to 20 updates a second.

## Results

| Kind | Files | Format |
| --- | --- | --- |
| thumbnails | `strip.json`, `t00000.jpg`... | `ThumbnailStrip`; file i shows time i * interval (2 s), 320 px wide; images get one |
| waveform | `waveform.json`, `peaks.f32` | header plus little-endian Float32 peaks, 100 a second, the loudest sample over all channels, placed by sample time |
| loudness | `loudness.json` | `Loudness`; silence is `-inf` (written as the string "-inf") |
| proxy | `proxy.mov` | 1080p box, aspect kept, all-intra HEVC at quality 0.45, video only, every frame at its exact source time and duration, source colour tags and rotation |
| transcript | `transcript.json` | `Transcript`, engine "SpeechAnalyzer", en-US, word times in media time |
| matte | `matte.mov` | 1080p box, HEVC, keyframe every 10 frames; luma of full-range (420f) frames is the alpha (0 background, 255 person), chroma neutral, BT.709 tags, source frame times and rotation |
| isolatedVoice | `voice.caf` | 48 kHz ALAC, source channels (max 2), same length as the source, lined up to the sample |

Notes on each:

- **Proxy.** Decoded frames carry no duration, so each frame is encoded one
  frame late, when the next one says how long it lasted; the last runs to
  the track end. Writing passes VideoToolbox's samples straight into
  AVAssetWriter with the source's timescale, so nothing is rounded.
- **Transcript.** Audio streams from the file a second at a time as the
  analyzer pulls it (the whole 24 minute take peaks at 53 MB). The model
  works although AssetInventory says only "supported"; if analysis ever
  fails for that reason the job installs the model and retries once.
  SpeechAnalyzer's word ranges swallow surrounding silence (in the spike
  they covered 8.7 of 11.7 s of pauses), so words are trimmed to their
  voiced part using a 100 Hz loudness envelope of the same audio: a word
  starting or ending in 100 ms or more of quiet moves in, with 20 ms / 40 ms
  of padding. On the test minute that finds 5 pauses over 0.3 s (5.4 s),
  against 1 (3.1 s) without and 8 (6.9 s) for Whisper medium.en; word
  starts stay within 80 ms of Whisper's (median).
- **Matte (version 2).** Per frame, accurate person segmentation
  (2016x1512) and the foreground subject mask
  (`VNGenerateForegroundInstanceMaskRequest`, "lift subject", 512x512),
  blended by `MatteBlender.keepSubject`. The subject mask holds still and
  has the mic but misses a hand held away from the body; the person mask
  has the hand but shimmers, drops the mic and grabs half-sure bits of sofa
  and desk. So the subject adds itself inside the person's hull (the person
  mask closed over a third of the frame height, grown by 6%, in or out);
  within 1.1% of the frame height of the subject the person mask counts as
  it is; further out only confident person pixels count (0.6 to 0.95
  stretched to 0 to 1). No subject found: the person mask. Then
  `MatteSmoother`, four frames behind: a median of three frames, a median
  of seven and a gentle average, each only where a quarter-size luma and
  chroma picture of the source is still, so a moving hand is never
  averaged, trailed or cut. `matteProps: .personInstances` with
  `matteSmoothing: .off` still makes version 1 (person instance mask filling
  holes of the closed person mask, per frame).

  Why: Mike saw the cutout flicker. Scored on 20 s where he talks and
  gestures in two takes (A: 105434 from 294 s, B: 144426 from 334 s) as the
  mean matte change (0 to 255) between frames where the picture barely
  changed, plus frames where a patch of more than 0.25% of the still
  picture flips, and those flips over the mic:

  | Matte | Flicker A / B | Pop frames A / B | Mic pops A / B |
  | --- | --- | --- | --- |
  | Version 1: accurate + person instances | 1.51 / 2.15 | 74 / 130 | 20 / 102 |
  | Accurate alone (no mic) | 1.65 / 2.24 | 81 / 106 | |
  | Balanced alone | 1.56 / 2.17 | 46 / 59 | |
  | Fast alone | 0.50 / 0.46 | 54 / 36 | twice the pops where he moves, coarse edges |
  | Subject mask alone | 0.10 / 0.09 | 10 / 9 | loses hands held out |
  | Version 2 blend, per frame | 0.60 / 0.84 | 72 / 92 | 7 / 12 |
  | Version 2 with smoothing (the default) | 0.17 / 0.20 | 12 / 14 | 2 / 2 |

  The flicker was three things: the instance blend dropping the mic (B:
  on 102 of 600 frames), the accurate mask's outline shimmering (about
  30/255 a frame along the edge where nothing moved) and one-frame grabs
  of sofa and desk. The HEVC encode adds nothing. Also tried: a guided
  filter (softer edges, more flicker), a plain moving average (trails
  behind hands), a plain median of three (cut the fingers off a fast
  swipe, now gated), optical flow (19 ms a frame, too slow to be the
  default). Not tried: RVM (GPL-3.0; its Core ML weights would have to be
  downloaded at runtime, never bundled) and MODNet (Apache-2.0, per frame,
  also a download plus a Core ML conversion). What's left: when Vision
  grabs sofa for a frame right beside a fast-moving arm, the smoother
  leaves it, since that area moved.

  Vision's guess on a frame with no person can be noise. Frames Vision
  fails on hold the frame before. `matteURL(for:mode:)` finds a `.person`
  matte if one was made with that setting. The segmentation request is
  stateful, but three workers sharing frames, a fresh request per frame
  and one worker in order give byte-identical mattes (measured on 20 s of
  the camera), so the workers take frames in any order.
- **Isolated voice.** AUSoundIsolation (voice model, 100% wet) in offline
  manual rendering. The unit's reported latency (3,665 samples in stereo,
  2,705 in mono) is dropped from the front and fed as silence at the end,
  silence is added in front if the audio starts after zero, and output
  stops at the source's length (resampled sources are padded to it). Both
  layouts line up within a sample on the real footage. The render module mixes it with the original by
  `voiceIsolation`.

## Wiring it up

- The session should start a `FolderWatcher` when a project opens, call
  `refreshMedia()` on each batch (it already calls `requestDefaults`), and
  stop it on close. `scanReport` also returns missing files and notes
  (clamped take offsets) worth showing.
- Exports should `await EncoderLock.shared.acquire(priority: .export)`
  before encoding and `release()` after; proxy and matte builds hand the
  encoder over within a fifth of a second.
- `isCached(_:for:)` and `state(_:for:)` answer "is it ready" without
  decoding a transcript or waveform.
- A clip whose cutout mode is `.person` can have its matte made with
  `submit(.matte, for:, settings:)` (matteMode `.person`) and read with
  `matteURL(for:mode:)`.
- Matte version 2 changed the cache key, so every matte rebuilds once;
  the version 1 entries go least recently used first once the cache is
  over its size limit. `matteProps` and `matteSmoothing` are in the key
  too.

## Speed on the M5 Pro

Real footage, release build (`report.txt` has the latest numbers):

| Job | Measured |
| --- | --- |
| Scan decision-models (295 files) | 0.43 s, rescan 0.01 s |
| Loudness, 24 min camera | 1.0 s on a quiet machine (up to 5.7 s while other builds ran); -32.11 LUFS, LRA 11.75, TP -5.30 (ffmpeg: -32.1, 11.8, -5.3) |
| Waveform, 24 min camera | 1.0 s quiet, up to 4.3 s under load |
| Thumbnails, 24 min camera | 724 JPEGs in 3.4 to 4.2 s |
| Proxy | 489 fps for 4K camera and VFR screen (about 1.5 min for a 24 min take), 5 Mbps camera, 7.4 Mbps screen |
| Transcript | 65x realtime for a minute, whole take in 11 s (132x) |
| Matte | 41 fps with 4 workers (18 min for a 24 min take, 1.4x real time at 30 fps); the Neural Engine is the limit, the smoother (about 10 ms a frame) hides behind it. Version 1 was 49 to 52 fps |
| Isolated voice | 38x realtime, within 1 sample of the original |
| Every default for a 43 s take, background priority | 33 s, the matte last |

## Tests

```bash
swift test --package-path tools/tandem                      # about 9 s of media tests
TANDEM_REAL_MEDIA=1 swift test -c release -Xswiftc -enable-testing \
  --package-path tools/tandem --filter RealMediaTests       # about a minute
TANDEM_REAL_MEDIA_FULL=1 ...                                # adds the whole-take transcript
```

The default tests make their media on the fly (AVAssetWriter frames and
sines, AVSpeechSynthesizer speech for the transcript). Real-footage tests
read `~/dev/convex/convex-videos/decision-models` and write only to
`/private/tmp/claude-501/tandem-media/real/`, including matte cutout stills.
