# Tandem media

How `TandemMedia` finds, describes and analyses the files in a video
folder. `ARCHITECTURE.md` is the contract; this is the detail behind it.

| File | What it does |
| --- | --- |
| `MediaScanner.swift` | Walks the folder, matches known items, roles |
| `CameraTakes.swift` | Camera takes nothing names: a recording with a voice and a face |
| `LivePhotos.swift` | A Live Photo's still and movie as one item |
| `MediaProbe.swift` | AVFoundation and ImageIO probing, frame timing, alpha |
| `Fingerprint.swift` | `size-mtime-sha256` identity |
| `TakePairing.swift` | record-it takes and the `.take.json` sidecar |
| `FolderWatcher.swift` | FSEvents, debounced, settled |
| `AnalysisCache.swift` | `.tandem/cache/<kind>/<key>/`, atomic commits, eviction |
| `JobScheduler.swift` | Priorities, limits, dedupe, preemption, cancellation |
| `MediaAnalysis.swift` | The public face: cached reads, requests, state |
| `AnalysisSettings.swift` | Per-kind settings and algorithm versions |
| `AudioJobs.swift`, `ThumbnailJob.swift`, `VideoIO.swift` (proxy), `TranscriptJob.swift`, `MatteJob.swift`, `IsolatedVoiceJob.swift`, `ConvertJob.swift` | The analyses |
| `FFmpeg.swift`, `HEVCTranscoder.swift` | ffmpeg, and video macOS can't decode to HEVC with alpha (shared with the asset library) |
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

### Files macOS can't decode

Stock alpha stickers (Storyblocks, Motion Array, older VideoHive packs)
often come as QuickTime Animation (`rle `) or PNG (`png `) in a MOV, and
macOS 26 has no decoder for either. Their sample tables read fine, so they
scan like any video, but one such clip on the timeline failed every render
with "Cannot Decode".

- The probe asks the video track whether AVFoundation can decode it
  (`isDecodable`, no frames read). When it can't, the item's
  `undecodableCodec` holds the codec's four characters.
- A `converted` analysis makes a copy that does decode: ffmpeg writes ProRes
  4444 (422 HQ without alpha) and AVFoundation's HEVC-with-alpha export
  preset encodes that (`HEVCTranscoder`, which the asset library uses for
  WebM too). Animation and PNG frames are RGB, so they're converted with the
  BT.709 matrix and the frames tagged BT.709: ffmpeg ignores `-colorspace`
  here, and untagged, the export guessed SMPTE-C for a small picture and
  turned red (255, 0, 0) into (223, 29, 0). WebM is YUV already and is
  tagged with what that YUV is (ASSETS.md, WebM colour). The copy is video
  only, at the original's size and frame times, with straight alpha; the
  sound plays from the original.
- `AnalysisNeeds` asks for the conversion first, for every such file in the
  folder, so the browser can show it. Thumbnails, proxies and mattes of the
  file are made from the copy: asking for one before the copy exists queues
  the conversion and then that job.
- Frame grabs and exports wait for any conversion they need (docs/RENDER.md);
  the viewer leaves the clip out until the copy lands.
- ffmpeg is found through `TANDEM_FFMPEG`, the PATH, `~/.local/bin`, then
  Homebrew. Without it the conversion fails, saying to install it, and the
  file is left out of renders with that warning.
- Scans before Tandem checked this didn't mark such files. A rescan gives
  alpha video without the mark a quick look (its header, under a
  millisecond; HEVC and ProRes are skipped, since asking about HEVC with
  alpha takes 5) and probes it again if macOS can't decode it, and renders
  check the files they show.

Roles, in order: `-camera` / `-screen` record-it names, the nearest folder
that says what it holds (`music`, `sfx`, `broll`, `graphics`,
`motion-graphics`, `stickers`...), words in the file name, then the kind.
Stray audio under 10 s is `sfx`, longer is `music`. A new video none of
that explains can still be a camera take (below). Roles are only worked out
for files new to the project, so a role Mike changed stays changed.

### Camera takes nothing names

A phone video of Mike talking to the camera (`source/IMG_0151.MOV` in the
workbench short) used to be `other`, so it got no transcript until its role
was set by hand. `CameraTakes` makes a new video that nothing else explains
(role `other`, with picture and sound, 4 s or longer) the camera take when
all three hold:

- **A recording, not a render.** Its metadata names the camera that shot
  it (phones and cameras write their make and model: "Apple iPhone XS
  Max"), or it's in `source/`. Renders of an edit have a voice and a face
  too, and Mike's Filmora-era folders keep them beside the project
  (`Decision Models v14.mp4`, `edit/preview/s060.mp4`); none of them has a
  camera's make or model.
- **A voice.** Apple's built-in sound classifier
  (`SNClassifySoundRequest`, `.version1`, 1.5 s windows) runs over six 3 s
  stretches spread across the file (all of it when it's under 18 s), and
  hears speech (confidence 0.5 or more) in at least a quarter of the
  windows, and two or more. The workbench selfie scores 22 of 22; record-it
  camera takes, with typing and pauses, 7 to 15 of 22; a record-it screen
  recording, a Live Photo movie and a phone clip of the finished bench
  with no talking, 0. About 0.1 s a file.
- **A face.** Vision (`VNDetectFaceRectanglesRequest`) finds a face at
  least a tenth of the frame high in two of six frames, with the file's
  rotation applied. The selfie's faces are 0.22 to 0.41 of the frame high,
  record-it takes' 0.24 to 0.35. This keeps out a narrated screen
  recording, and phone footage of hands at work with a voice over it
  (`photos/IMG_0141.MOV`: speech 21 of 22, no face). A PiP render has faces
  of 0.12 to 0.16, which is why renders are kept out by the first rule.

`tandem new` prints each camera take with its reason and the `updateMedia`
that changes it (`ScanReport.cameraTakes`, through
`ProjectSession.refreshMediaReport`). The app's single-file probe, for
files dropped from Finder, runs the same check; a dropped video lands in
`broll/`, which says what it is, so the check only matters for a file
already in the folder.

### Live Photos

Photos, AirDrop and Image Capture give a Live Photo as two files with one
name: the still (`IMG_0130.HEIC`, or a JPEG) and a movie of 1 to 3 s
(`IMG_0130.mov`). Added separately, 35 photos made 71 media items. Now the
still is the item and records the movie in `livePhotoVideo`; the movie
isn't media of its own.

- A pair is a HEIC, HEIF or JPEG and a `.mov` in the same folder with the
  same name, ignoring case. When both carry Apple's content identifier (the
  still's maker note key 17, the movie's
  `com.apple.quicktime.content.identifier`), those decide. Otherwise the
  movie has to look like one: 5 s or less, a picture, no alpha. So a long
  video that shares a photo's name, or an animated logo beside a PNG, stays
  a video.
- Only movies new to the project pair. A movie a project already has as
  media (every Live Photo made before this, maybe on the timeline) stays as
  it is.
- Once paired, a scan skips the movie without probing it. A still whose
  movie has gone forgets it; a movie that lands after its still joins it.
- Dropped on the app, a movie goes beside its still (`graphics/`, or
  `linked-media/` from another disk), with the still's name if that had to
  be numbered, and is recorded on it.
- Left: if Photos writes a movie before its still and the folder watcher
  scans in the moment between, that movie becomes an item of its own. Both
  halves of an export land in the same second, well inside the watcher's
  settle time, so it hasn't been seen.

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
  (conversion, waveform, loudness, thumbnails, transcript, proxy, isolated
  voice, matte), then first come. Conversions go first because a file's
  other picture analyses wait for them.
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
| proxy | `proxy.mov` | 1080p box, aspect kept, HEVC with a keyframe every 15 frames and P-frames between (no reordering) at quality 0.78, video only, every frame at its exact source time and duration, source colour tags and rotation. Video with alpha gets HEVC with alpha, straight or premultiplied as the source is |
| transcript | `transcript.json` | `Transcript`, engine "SpeechAnalyzer", en-US, word times in media time |
| matte | `matte.mov` | 1080p box, HEVC, keyframe every 10 frames; luma of full-range (420f) frames is the alpha (0 background, 255 person), chroma neutral, BT.709 tags, source frame times and rotation |
| isolatedVoice | `voice.caf` | 48 kHz ALAC, source channels (max 2), same length as the source, lined up to the sample |
| converted | `video.mov` | Only for `undecodableCodec` files: HEVC, with alpha when the source has it, BT.709 tags, the source's size and frame times, video only |

Notes on each:

- **Proxy.** Decoded frames carry no duration, so each frame is encoded one
  frame late, when the next one says how long it lasted; the last runs to
  the track end. Writing passes VideoToolbox's samples straight into
  AVAssetWriter with the source's timescale, so nothing is rounded.

  Version 3 has a keyframe every 15 frames (`proxyKeyFrameInterval`) with
  P-frames between, at quality 0.78. Versions 1 and 2 were all keyframes
  (at 0.45, then 0.6), so their compression noise was new every frame and
  crawled over still walls and screen text while playing; a P-frame leaves
  a still area as it was. The box, keyframe interval and quality are all in
  the cache key. docs/RENDER.md has the flicker, size and seek numbers.

  Overlays and stickers bigger than 1080p get proxies too, and those keep
  their alpha. Until 2026-09-29 every proxy was plain HEVC made from 4:2:0
  frames, so with Proxy on the viewer played a black box behind an HEVC
  overlay (premultiplied, so black under the clear parts), or the colour
  straight alpha keeps there for ProRes 4444 and converted stickers, while
  paused frames and exports, read from the original, were right. Now
  `VideoFrameReader` reads video with alpha as BGRA (`keepingAlpha`), each
  frame tagged `AlphaChannelMode` as the decoder found it: straight for
  ProRes 4444 and converted copies, premultiplied for HEVC with alpha from
  AVAssetWriter. The HEVC-with-alpha encoder takes the mode from the first
  frame's tag (premultiplied when there's none, as Core Image assumes), so
  the proxy blends like the original. The file says `hvc1` with the
  ContainsAlphaChannel extension, not `muxa`.

  Only those proxies changed, so the proxy version stays 3. Their cache key
  adds `"alpha":"1"` (`AnalysisSettings.canonical(for:item:)`, from the
  item's `hasAlpha`), which retires any opaque one made before; every other
  proxy keeps its key and its file. HEVC's alpha layer brings opaque back as
  251 to 253 (an HEVC sticker from AVAssetWriter decodes as 253 itself) and
  `TargetQualityForAlpha` doesn't change that; half and clear come back
  exact.

  A 10 s 4K ProRes 4444 overlay with a moving soft edge proxies in 1.4 s to
  15.5 MB, where an opaque proxy took 0.7 s and 14.4 MB, and the proxy
  decodes at 1,135 fps against the original's 393 (BGRA, M5 Pro). The
  alternative, playing big overlays from the original, costs most for
  converted stickers: the export preset's 4K HEVC copy has a keyframe about
  every 28 frames with reordering and decodes at 350 fps, so an exact seek
  can decode 28 frames of 4K instead of at most 15 at 1080p.
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
- **Matte (version 2, Vision).** RVM (below) is the default now; this is
  what it falls back to. Per frame, accurate person segmentation
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
  | Version 2 with smoothing (now RVM's fallback) | 0.17 / 0.20 | 12 / 14 | 2 / 2 |

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
- **Matte with RVM (the default, `matteModel: .robustVideoMatting`).**
  Robust Video Matting's own Core ML export of its MobileNetV3 model
  (1280x720 input, downsample ratio 0.375 built in), run on the GPU one
  frame at a time with its recurrent state carried from frame to frame,
  frames letterboxed into the model's input and the alpha scaled up to the
  matte box. The RVM repository is GPL-3.0 (the model file's metadata says
  Apache 2.0; Tandem goes by the repository), so the 7.5 MB model is never
  committed or bundled: `RVMModelStore` downloads it from the official
  v1.0.0 release on first use into
  `~/Library/Application Support/Tandem/Models/rvm/` and checks its
  SHA-256. Tests never download it (the store refuses while XCTest is
  loaded). Both cutout modes share one RVM matte; its cache key has its own
  version (`RVMMatte.version`, 2 since the edge fix). Making RVM the default
  changed the matte key, so existing Vision mattes rebuild with RVM.

  RVM's soft edge took some of the wall with it: a light rim around the cap
  and shoulders, worst over dark UI, because the renderer applies the alpha
  to the source's own colours. `RVMMatte.cleanEdge` chokes the alpha by a
  pixel at 1080p and clears alpha under 0.3, stretching the rest back to
  0...1. The light the rim adds (alpha times how much brighter the edge is
  than the person just inside, where the picture is still) drops to 32% and
  33% on the two ranges; 98% of the alpha where hands move stays, and fast
  swipes keep their motion blur. A 2 px choke took the rim to 26% but shaved
  the ear; a higher floor would start on fine hair. Using RVM's own
  foreground output to decontaminate the colour would need the renderer to
  carry a second picture, so it isn't done.

  Scores through the job on the two ranges (A / B): flicker 0.066 / 0.062
  (version 2: 0.17 / 0.20, RVM before the edge fix 0.082 / 0.070), pop
  frames 0 / 1, the mic kept on 99.1% of B. Speed: 40 fps on a quiet
  machine before the edge fix, 36 to 38 with it while other work ran.

  If the model can't be downloaded or loaded, the job makes the version 2
  Vision matte instead and says so: its status keeps "Made with Vision: RVM
  unavailable (why)" after it finishes, and `fallback.json` in the entry
  records the model file's size and date. Once that file changes (the
  model arrived or was replaced) `MediaAnalysis` counts the matte as
  missing and rebuilds it once, serving the fallback meanwhile; a rebuild
  that falls back again records the new state, so it never loops.
- **Isolated voice.** AUSoundIsolation (voice model, 100% wet) in offline
  manual rendering. The unit's reported latency (3,665 samples in stereo,
  2,705 in mono) is dropped from the front and fed as silence at the end,
  silence is added in front if the audio starts after zero, and output
  stops at the source's length (resampled sources are padded to it). Both
  layouts line up within a sample on the real footage. The render module mixes it with the original by
  `voiceIsolation`.
- **Converted.** A 2 s 512x512 Animation or PNG sticker converts in about a
  quarter of a second; 10 s of 1080p30 Animation (118 MB) takes 3.9 s and
  makes an 11 MB copy. The ProRes intermediate sits in the job's folder and
  is gone before the result is committed.

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
| Proxy | About 480 fps for 4K camera and VFR screen: 3.7 s a minute of camera, 2.3 of screen recording. Version 3 is 97 MB a minute of camera (13 Mbps), 11 of screen (1.5 Mbps) |
| Transcript | 65x realtime for a minute, whole take in 11 s (132x) |
| Matte, RVM (the default) | 40 fps on a quiet machine before the edge fix, the same as version 2 (GPU, one frame at a time); 36 to 38 with the edge fix while other work ran |
| Matte, Vision (fallback) | 41 fps with 4 workers (18 min for a 24 min take, 1.4x real time at 30 fps); the Neural Engine is the limit, the smoother (about 10 ms a frame) hides behind it. Version 1 was 49 to 52 fps |
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
