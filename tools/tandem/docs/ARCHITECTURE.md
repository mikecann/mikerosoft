# Tandem architecture

Tandem is a native macOS video editor built for one person (Mike) and the
agents he works with. It replaces Filmora for Convex developer videos: a
camera take and a screen recording cut together, a picture-in-picture camera
with an AI cutout, B-roll, titles, music, sound effects and a loudness-matched
export. Anything the app can do, an agent can do through the same commands.

This file is the contract between the modules. If you change a rule here,
change the code and the tests with it.

## Principles

- **One way to change a project.** Every edit is an `EditCommand` in an
  `EditBatch`, applied by `ProjectCoordinator`. The UI, the CLI and agents all
  go through it. Views never mutate the model directly.
- **Conventional tracks.** Tracks with gaps, like Premiere and Resolve, not a
  magnetic timeline. Ripple behaviour comes from each track's `rippleMode`.
- **Data over code.** Effects, transitions, title styles, stickers, sounds and
  keymaps are data in packs. New Swift is for new kinds of thing (a new node
  type, a new command), not new content.
- **Fast feedback beats features.** Playback, scrubbing and export speed come
  before breadth. Proxies, caches and background jobs exist to keep the UI
  responsive.
- **Just for Mike.** No accounts, no cloud, no plugins marketplace, no
  permission system beyond a toggle. Hackable by editing the repo.

## Modules

| Target | Owns | May import |
| --- | --- | --- |
| `TandemCore` | Model, time, commands, editing, validation, undo, journal, effect registry | Foundation |
| `TandemMedia` | Folder scanning, probing, take pairing, analysis jobs and cache | Core, AVFoundation, Vision, Speech, VideoToolbox, Accelerate |
| `TandemRender` | Composition building, compositor, text, transitions, audio mix, frame grabs, export | Core, Media, AVFoundation, Core Image, Metal |
| `TandemAPI` | `ProjectSession`, the service (status, timeline, apply, frame, clip, export...), local HTTP server, MCP tool definitions | Core, Media, Render |
| `TandemApp` | The macOS app (SwiftUI shell, AppKit timeline and viewer) | everything |
| `TandemCLI` | The `tandem` command, including `tandem mcp` and `tandem export` | Core, Media, Render, API |
| `TandemAssets` | Asset library: catalogue, providers, normalising on import, copying into projects, credits (see ASSETS.md) | Core, Media, AVFoundation, ImageIO, Core Text, Lottie |

Only `TandemApp` imports AppKit or SwiftUI. One exception: the asset
library's SVG rasteriser uses `NSImage`, the only SVG renderer macOS has,
drawing into its own bitmap off the main thread.

## Project folder

A project is a `.tandem` JSON file in the video's folder. Media paths are
relative to that folder when the file is inside it; a file used from
somewhere else (an import, another video's folder) has an absolute path
until the project is archived (see Archiving).

```
<video folder>/
  <name>.tandem            the project (pretty JSON, sorted keys)
  source/                  record-it takes: <base>-camera.mov, <base>-screen.mov
  broll/ music/ sfx/ graphics/
  assets/                  library assets in use (assets/<kind>/), and LUTs and fonts
  media/                   files an archive brought in from outside the folder
  archive.json             where those came from, once the project is archived
  exports/                 renders, each with a .tandem snapshot beside it
  .tandem/
    backups/               the previous 20 saves
    <name>.journal.jsonl   committed edits since the last save (crash recovery)
    <name>.undo.json       undo history for edits made headless, and idempotency keys
    <name>.lock            pid and owner (app or cli), plus the API port and token
    cache/                 analysis results keyed by content hash
```

Versions are separate files (`Video v2.tandem`), made with Save As. There are
no forks or branches inside a project.

## Model conventions

- IDs are short strings with a prefix: `clip_`, `trk_`, `med_`, `tr_`, `fx_`,
  `mk_`, `lnk_`. They never change. When a clip is split, the left part keeps
  the ID and the right part gets a new one.
- `Time` is an integer count of flicks (1/705,600,000 s), exact for every
  common frame rate and sample rate. JSON writes seconds rounded to 6
  decimals; decoding snaps to the 48 kHz sample grid.
- JSON decoding is lenient: missing fields get defaults, so agents can send
  only what they mean (`{"content": {...}, "start": 3, "duration": 2}`).
- Video tracks are listed bottom to top (`videoTracks[0]` draws first). The UI
  shows them top to bottom, highest track first.
- Video-track clips are silent. Sound always lives on audio tracks, linked to
  its picture with a shared `linkGroup`.
- A camera file's colour grade lives on the media (`MediaItem.look`), so every
  clip from that file gets it. Clip effects come after the look.
- Keyframe times are relative to the clip start and move with the clip.
- Adding a field that matters means bumping `Project.currentSchemaVersion`
  (with a `ProjectFile.migrate` step if old files need it). Lenient decoding
  lets an older build open a newer file, and it would silently drop the new
  field when it saves; the version check makes it refuse instead.
  `settings.speechLoudness` didn't need one: every clip stores its own
  `normalizeTo`, so an older build that drops it only resets the level new
  clips get to -20 LUFS, and the project sounds the same.
- Backups live in `.tandem/backups/`: one at most every minute of saving,
  everything from the last hour, one per ten minutes for a day, one per day
  for 30 days (`BackupPolicy`). Exports only replace earlier Tandem exports
  (the ones with a `.tandem` snapshot beside them).

## Editing

`ProjectCoordinator.apply(batch)` copies the project, applies every command,
validates the result and commits only if all of it worked. Each commit bumps
`revision`, becomes one undo step labelled with the batch label and author,
is appended to the journal (with the ID seed, so a replay recreates the same
IDs) and is announced to observers.

`expectedRevision` lets an agent refuse to edit a timeline that changed under
it. `idempotencyKey` makes retries safe.

### Ripple modes

Each track has a `rippleMode`:

- `cut` (Screen, Camera, Voice): the tracks that hold the take. A ripple edit
  on one of them cuts the same time out of every `cut` track, so the take
  stays in sync.
- `follow` (B-roll, Graphics, Text, Music, SFX): clips move with the content
  around them but aren't cut. A music bed or B-roll shot that spans deleted
  time keeps playing from its head and loses that much from its tail. A clip
  entirely inside deleted time is removed (with a warning).
- `off`: ripple edits elsewhere leave the track alone.

A ripple edit made on a `follow` or `off` track only ripples that track, so
closing a gap in the B-roll never touches the take. Markers move with global
ripples. Locked tracks never move (with a warning).

`rippleDeleteRange` is the workhorse for tightening pauses: by default it cuts
every `cut` track and lets the rest follow. `closeGap` refuses when another
`cut` track has content in the gap.

### Linking

Clips placed together from one take (camera picture, camera sound, screen)
share a link group. Selection, moves, trims, blades, slips and speed changes
apply to the whole group unless `includeLinked: false`. When linked clips are
split at the same time, their right-hand parts form a new group together.

### Transitions

A transition belongs to a track and joins two touching clips (`fromClipID`,
`toClipID`) or sits at one clip's head or tail (the other side nil). A
two-sided transition is centred on the cut and needs half its duration of
spare media (handles) on both clips; the command fails with a clear message
otherwise. On audio tracks every transition plays as a crossfade.

## Transform contract

The viewer and the export must agree exactly:

1. The source frame is aspect-fitted into the canvas, then multiplied by
   `transform.scale`. Scale 1 fits; 0.5 is Mike's PiP.
2. `transform.position` is where the centre of the uncropped source lands, in
   canvas units: (0, 0) top left, (1, 1) bottom right. Mike's 2026 PiP is
   scale 0.5 at about (0.87, 0.77).
3. `transform.rotation` is degrees clockwise about that centre.
4. `crop` hides fractions of the source edges without rescaling.
5. Opacity multiplies the layer, including its shadow.
6. The cutout matte multiplies alpha before the drop shadow is drawn, so the
   shadow follows the person.

Zooming a screen recording to a rectangle R (source units) on a same-aspect
canvas is `scale = min(1/R.width, 1/R.height)` with the position moved so R's
centre lands on the canvas centre.

## Media and analysis

`MediaScanner.scan` finds media in the project folder and pairs record-it
takes by base name (`<base>-camera.mov` with `<base>-screen.mov`), setting a
shared `takeID` and each file's `takeOffset`. When record-it writes a
`<base>.take.json` with each file's start host time, pairing uses that;
otherwise it uses file creation times.

`MediaAnalysis` runs background jobs through one scheduler with priorities
(`interactive`, `timeline`, `background`) and an encoder lock, so proxy builds
and exports never fight over the hardware encoder.

What gets analysed follows the edit (`AnalysisNeeds`), because a video folder
can hold hundreds of files that never go near the timeline. Everything gets
the cheap ones (thumbnails, waveform, loudness) and every camera take gets a
transcript, so you can search what you said before placing it. The expensive
ones only run for what the edit uses: proxies for large video on the
timeline, a cutout matte once a clip's cutout is on, isolated voice once a
clip uses voice isolation, and a transcript for anything on a speech track.
Long-lived sessions (the app, `tandem serve`) re-check after every burst of
edits, so placing a take or pressing 2 for the PiP queues its work. Results are cached under `.tandem/cache/<kind>/<key>/` where
`key = sha256(fingerprint, kind, algorithmVersion, settings)`.

| Kind | Result | Notes |
| --- | --- | --- |
| thumbnails | JPEG strip | for the timeline and browser |
| waveform | peak envelope | drawn on audio clips |
| loudness | integrated LUFS, true peak, LRA | per file; dialogue is levelled per take, not per cut |
| proxy | 1080p HEVC, a keyframe every 15 frames | used for motion; paused frames decode the original |
| transcript | words with media times | SpeechAnalyzer first; Whisper medium.en as the careful pass |
| matte | greyscale HEVC person matte | Vision person segmentation, blended with the instance mask to keep a handheld mic |
| isolatedVoice | audio file | AUSoundIsolation, shifted back by its 3,665-sample latency |

## Rendering

`CompositionBuilder` turns a project into an `AVMutableComposition`, an
`AVVideoComposition` driven by Tandem's own `AVVideoCompositing` compositor,
and an `AVAudioMix`. The viewer plays it with `AVPlayer`; `FrameRenderer`
grabs single frames; `Exporter` reads it with `AVAssetReader` and encodes with
VideoToolbox (speed priority) into `AVAssetWriter`.

Audio rules:

- Clip gain, fades and volume keyframes become volume ramps.
- `normalizeTo` levels a clip using its file's measured loudness: the
  target minus the measurement, within ±30 dB, nothing for a silent file.
  The clip gain is added after it (`AudioLevels`).
- Speech (a camera's sound, a file with no clearer role, anything on a
  `cut` audio track like Voice) is levelled per take to the project's
  speech level, `settings.speechLoudness` (-20 LUFS): placing sets it with
  no gain, `normalizeSpeech` sets every speech clip to it, and changing the
  setting moves the clips at the old level. Music (-31 dB) and sound
  effects (-15 dB) keep plain gains set against that voice. RENDER.md has
  why -20.
- `voiceIsolation` mixes the cached isolated voice with the original.
- Every hard cut on an audio track gets a 3 ms micro-fade so nothing clicks.
- Export measures the mix and applies gain to hit the master loudness target
  (-14 LUFS) under the true-peak ceiling (-1 dBTP).

Colour: sources are treated as BT.709 SDR, honouring each file's video range;
exports are tagged TV-range BT.709.

## API

`ProjectSession` opens a project, replays the journal after a crash, takes the
lock and autosaves a second after each edit. A save clears only the journal
entries it wrote, and saves and the journal follow the folder if it's renamed
or moved while the project is open. While the app has a project open
it serves a local HTTP API on 127.0.0.1 (port and token in the lock file) and
the CLI talks to it. When no app has the project open, the CLI opens the file
itself.

Operations: `status`, `media`, `transcript`, `search`, `timeline`, `apply`,
`undo`, `redo`, `frame`, `screenshot`, `clip`, `export`, `loudness`,
`validate`, `watch`, `archive`, `relink`. `tandem mcp` exposes the same
operations as MCP tools over stdio. Every edit an agent makes shows up in the
app's activity feed and undo menu under the agent's name.

## Archiving

A project folder is standalone when everything the project uses is inside
it, so it opens on another Mac (Bruce, where finished videos live) with
nothing missing. `ProjectArchiver` in TandemAPI makes it so, for `tandem
archive`, the `archive` operation (HTTP and MCP) and File > Archive
project… in the app. It works on an open `ProjectSession`: the project is
saved first, and the one change it makes to a project is an edit through the
coordinator, so the lock, journal, undo and autosave rules hold. It looks at
the open project and every other `.tandem` file in the folder (versions).

What counts as outside:

- a media file whose real path (links followed) isn't in the folder, which
  includes a link in the folder to a file somewhere else;
- the file a `lut` effect reads (`path`), on a clip or in a media look;
- a font a title uses (its own or its preset's) that doesn't come with macOS
  and isn't in `assets/font/`, found through Core Text and then in the asset
  library's downloaded fonts;
- a record-it take's `<base>.take.json`, which goes with its take.

A reference to a file inside the folder written as an absolute path (or
with `..`) is made relative. Graphic templates, title presets and effects are
data, not files, so there's nothing to collect for them.

Where files go: `media/<the folder it was in>/<name>` (a take's files and
sidecar stay together, and `music/` or `sfx/` still say what's inside),
`assets/lut/<name>` and `assets/font/<name>`, which the app registers when it
opens a project. A file keeps the name the project used, even when that was
a link to a file called something else.

Two modes:

- **Consolidate** (no destination): the copies go into the project's own
  folder and the project points at them, as one undo step ("Bring 12 files
  into the project folder"). Other versions in the folder are pointed at them
  too, unless one is open somewhere else. Undo points the project back; the
  copies stay.
- **Archive** (`--to <folder>`): a standalone copy of the whole folder goes
  to `<folder>/<project folder name>` (`<name> 2` if that's taken by
  something else; an earlier archive of the same project is brought up to
  date), with the outside files brought in and the project files written
  with relative paths. The original folder is left as it was. Left out:
  proxies, mattes, thumbnails and isolated voice, which Tandem makes again
  for what the edit uses (`--with-cache` keeps them); `node_modules`; lock
  files, cache temporaries, and the archived projects' journals and headless
  undo history (they describe the old paths); links to things outside the
  folder. Transcripts, waveforms and loudness always go. Their cache keys
  come from the media fingerprints, which survive because copies keep
  modification dates.

Copying:

- `copyfile` with `COPYFILE_CLONE`: an APFS clone on the same volume (instant,
  no extra space until one side changes), a full copy otherwise, then data
  and dates alone when a file system refuses ACLs or extended attributes.
- Each file is copied once however many references it has, and files with
  the same content share one destination.
- A different file already at the destination is never replaced; the copy
  goes beside it (`bed 2.m4a`). A file with the same content is used as it
  is (the manifest's checksum and date spare reading it again).
- Every copy is checked: the original's SHA-256, the copy's size, and for a
  copy that isn't a clone its SHA-256 read back without the page cache, so a
  file on a network share is really read.
- Copies are written under a hidden name (`.name.tandem-copy`) and moved into
  place once checked. Consolidating keeps them hidden until all are done,
  then moves them and edits the project straight away, so the folder watcher
  never adds one as new media first.
- The destination is checked for room first (files that will clone don't
  count).

Stopping part way (Cancel, a crash, a share going away) changes nothing in
the project; whole hidden copies are kept and the next run carries on from
them. An archive elsewhere writes its manifest first, marked unfinished, and
the project files last, so a cut-short archive can't be opened as if it were
whole and the next run knows the folder is this project's.

`archive.json` in the standalone folder records the project (id, name, file),
every run (date, mode, from, to, machine, user, counts, finished or not), and
per file its path, original location, kind, size, SHA-256, modification date
and when it was archived. Consolidating lists what it brought in; archiving
elsewhere lists every file it copied except the analysis cache, and carries
over the project folder's own manifest. An `archive.json` that isn't
Tandem's is never written over. Missing files are listed there and in the
result, and left pointing where they did; everything else is archived.

When a project opens in the app with media missing, files moved within its
folder are relinked straight away and Mike is asked for a folder to search
for the rest. `MediaRelinker` takes a file with the same name and, when the
item has a fingerprint, the same content; `tandem relink --search <folder>`
does the same for agents.

## Packs

A pack is a folder with a `manifest.json`, watched and hot-reloaded:

```
packs/<name>/
  manifest.json          name, version, licence, contents
  effects/*.json         EffectDefinition, optionally bound to a Core Image filter
  transitions/*.json     name, parameters, Metal source (gl-transitions style: progress, from, to)
  titles/*.json          title presets: style, in and out animations
  stickers/              Lottie JSON or HEVC-with-alpha .mov, with metadata
  sounds/                audio files with tags
  keymaps/*.json         keyboard shortcuts
```

The inspector builds its controls from parameter definitions, so an effect in
a pack gets UI for free.

## Testing

- Core: unit tests for every command, plus random edit sequences that must
  keep the invariants (no overlaps, valid media ranges, linked clips aligned).
- Render: golden frames with a tolerance, a sync test (beep and flash),
  loudness within 0.5 LU of the target.
- API: session, lock, recovery, and the CLI end to end in headless mode.
- Archive: on temporary folders, both modes, copies checked byte for byte,
  runs stopped part way and run again, the copy opened with the original
  gone.
- Real footage: the decision-models project rebuilt from its EDL.

Run everything with `swift test --package-path tools/tandem`.
