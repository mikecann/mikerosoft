# Tandem for agents

Tandem is Mike's video editor. Anything he can do in the app, an agent can
do through the `tandem` command, the local HTTP API or MCP. All three speak
the same operations and the same edit commands, and every edit lands in the
app's undo menu and activity feed under the agent's name.

This guide covers setup, how editing works, every edit command with an
example, and recipes for the common jobs. `docs/ARCHITECTURE.md` is the
contract behind it.

## Setup

### The CLI

`build-app.sh` puts the command inside the app bundle:

```bash
bash tools/tandem/build-app.sh
ln -sf ~/Applications/Tandem.app/Contents/MacOS/tandem ~/.local/bin/tandem
tandem --version
```

While working on Tandem itself, `swift build --package-path tools/tandem`
builds it at `tools/tandem/.build/debug/tandem`.

Commands find the project from `--project <file.tandem or folder>`, then
`$TANDEM_PROJECT`, then the single `.tandem` file in the current folder or
the nearest parent that has one. A folder with several versions
(`Video.tandem`, `Video v2.tandem`) needs `--project`.

Set `TANDEM_AUTHOR=claude` (or pass `--author claude`) so your edits are
credited to you. Without it they show up as `cli`.

Output is plain text for reading. Add `--json` to any command for the JSON
result. Errors go to standard error with exit code 1 (2 for usage
mistakes); with `--json` the error is printed as `{"error": {...}}`.

```
tandem status                      revision, length, who has it open, jobs
tandem timeline [--summary] [--from T] [--to T] [--words] [--json]
tandem media [--refresh]           files, clip counts, analysis status
tandem transcript [<clip or media id>] [--from T] [--to T]
tandem search "<phrase>"           where a phrase is said
tandem pauses [--min 0.6]          silences between words
tandem tighten [--min 0.6] [--keep 0.15] [--apply]
tandem captions [--from T] [--to T] [--max-words 3] [--y 0.42] [--apply]
tandem short [--apply]             lay out a 9:16 short from the same edit
tandem apply <batch.json | ->      [--dry-run] [--expect N] [--label L] [--key K]
tandem undo [--expect N]    tandem redo    tandem history    tandem validate
tandem frame <time> [-o out.png]   tandem clip <start> <end> [-o out.mp4]
tandem export [--preset youtube4k] [-o out.mp4] [--from T] [--to T]
tandem loudness    tandem effects    tandem schema    tandem watch [--once]
tandem new <path.tandem>           tandem serve    tandem mcp
tandem import filmora <file.wfp> [--out DIR]     a Filmora project as a .tandem
tandem import edl [edl.json] --recipe decision-models [--out DIR]
tandem import compare <a.tandem> <b.tandem>      how two cuts of one take differ
tandem assets providers                          asset sources and what to fix
tandem assets search "<text>" [--kind sfx] [--provider id] [--online] [--limit n]
tandem assets use <id> [--at T] [--duration T]   copy into the project, add, place
tandem assets fetch <id>    tandem assets credits [--optional]
tandem assets generate sfx|music "<prompt>" [--duration s]    tandem assets install-starter
```

`tandem help <command>` explains each one.

Imports write `<out>/<name>/<name>.tandem` with a report beside it
(`<name>.import.txt` for people, `.import.json` for agents) listing anything
that couldn't be carried over. Filmora media paths saved on another Mac are
fixed with `--rewrite /Users/old/=/Users/new/`, and moved files are found
with `--search <folder>`.

### When the app is open

Only one process owns a project at a time. When the Tandem app has it open,
the app serves the API and every `tandem` command (and MCP tool call) goes
through the app, so your edits appear in front of Mike as you make them.
When the app is closed, each command opens the `.tandem` file itself, makes
the change, saves and lets go, usually in a few milliseconds. You don't
need to care which is happening; `tandem status` tells you.

`tandem serve` opens the project and serves the API headless until you stop
it with Ctrl-C (it saves on the way out). Use it for a long session with the
app closed, or to watch changes live. If Mike opens the project in the app
meanwhile, the app asks `tandem serve` to save and quit, and your next
command goes through the app instead.

### MCP

`tandem mcp` is an MCP server on stdin and stdout. Add it to Claude Code:

```bash
claude mcp add tandem -- ~/Applications/Tandem.app/Contents/MacOS/tandem mcp
```

Started from a video's folder it uses that folder's project. To pin one
project, or to use it from anywhere:

```bash
claude mcp add --scope user tandem -- ~/Applications/Tandem.app/Contents/MacOS/tandem mcp --project "/Users/m5-mike/dev/convex/convex-videos/decision-models/Decision Models.tandem"
```

Every tool also takes a `project` argument, so one server can work on any
project. Edits are credited to the client's name (`claude`, `codex`) unless
`--author` or `$TANDEM_AUTHOR` says otherwise.

For Codex, in `~/.codex/config.toml`:

```toml
[mcp_servers.tandem]
command = "/Users/m5-mike/Applications/Tandem.app/Contents/MacOS/tandem"
args = ["mcp"]
```

The tools mirror the operations: `status`, `timeline`, `media`,
`transcript`, `search`, `pauses`, `tighten`, `apply`, `undo`, `redo`,
`history`, `validate`, `frame`, `screenshot`, `clip`, `export`, `loudness`,
`watch` and `effects`, plus the asset library's `assets_search`,
`assets_use`, `assets_credits`, `assets_generate` and `assets_providers`.
Tool results are readable text; pass `json: true` for the raw JSON. `frame` and `screenshot` return the picture as an image.
The `apply` tool's input schema describes every edit command. The server
speaks both MCP revisions in use: the `initialize` handshake (2025-11-25 and
earlier) and the stateless 2026-07-28 revision.

### HTTP

The app (or `tandem serve`) listens on 127.0.0.1 on a random port. The port
and a bearer token are in the project's lock file,
`<video folder>/.tandem/<name>.lock`:

```bash
LOCK="$HOME/dev/convex/convex-videos/decision-models/.tandem/Decision Models.lock"
PORT=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['port'])" "$LOCK")
TOKEN=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['token'])" "$LOCK")
curl -s -H "Authorization: Bearer $TOKEN" -H "X-Tandem-Author: claude" \
  -d '{"commands": [{"blade": {"at": 12.5}}]}' "http://127.0.0.1:$PORT/v1/apply"
curl -s -N -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/v1/watch"
```

- `POST /v1/<operation>` with the same JSON the MCP tool takes. Operations
  without parameters also answer `GET`.
- `GET /v1/watch` streams server-sent events (`edit`, `undo`, `redo`,
  `reload`, `jobs`, `export`). Send `Last-Event-ID` to catch up after a
  reconnect.
- `GET /v1/schema` returns the edit batch JSON schema. `GET /v1/health`
  needs no token. `POST /v1/release` asks `tandem serve` to save and quit
  (the app refuses it).
- Errors are `{"error": {"code": "...", "message": "..."}}` with a matching
  status: 400 bad request, 401 token, 404 not found, 409 conflict (stale
  revision, overlap, locked, nothing to undo), 501 not built yet.

## How editing works

**One way to change a project.** Every change is an edit command in a
batch. A batch is applied to a copy of the project, validated, and committed
only if every command worked, so a failing command leaves nothing half done
and the error says which command failed and why. Each committed batch is one
undo step with a label and an author.

**Revisions.** Each commit bumps the project's revision. Read it from
`status` or `timeline`, and send it back as `expectedRevision`: if Mike (or
another agent) changed the timeline in the meantime the batch is refused
with a `staleRevision` error instead of editing something you haven't seen.
Re-read and try again.

**Dry runs.** `"dryRun": true` (or `tandem apply --dry-run`) checks a batch
on a copy and reports what it would do: warnings, clips added, removed and
changed, and the new length. IDs it reports are made up fresh by the real
run.

**Retries.** Give a batch an `idempotencyKey` and a retry with the same key
returns the first result instead of applying it twice.

**Undo.** `undo` reverts the last batch, whoever made it, so pass
`expectedRevision` to undo only if nothing happened since your edit. With
the app closed, undo history for CLI and MCP edits is kept in
`.tandem/<name>.undo.json`, so `tandem undo` works across commands. It's
dropped as soon as the project is edited somewhere that doesn't keep it
(the app has its own undo).

**IDs** are short strings with a prefix: `clip_`, `trk_`, `med_`, `tr_`,
`fx_`, `mk_`, `lnk_`. They never change. When a clip is split the left part
keeps its ID and the right part gets a new one. A batch returns the IDs it
created, in order, so you can refer to them next. To refer to something
inside the same batch, give it your own ID (`"id": "clip_title1"`).

**Times** are seconds on the timeline (`12.5`). The CLI and the API
parameters also take `mm:ss.mmm` (`01:23.500`). Inside edit commands use
numbers; strings like `"1:02.5"` are accepted but numbers are clearer.
`sourceStart` and `slip` deltas are in media time (seconds into the file).

**Validation.** Commands are checked against the schema before they run,
so a misspelt field is an error (`unknown field "rippel" (did you mean
"ripple"?)`) rather than silently ignored.

### Tracks

A new project has Mike's usual tracks. Video tracks are listed bottom to
top in the JSON (`videoTracks[0]` is V1 and draws first); the timeline view
shows them top to bottom like the app.

| Track | Kind | Ripple mode | Holds |
| --- | --- | --- | --- |
| Text (V5) | video | follow | titles and captions |
| Graphics (V4) | video | follow | motion graphics, stickers |
| B-roll (V3) | video | follow | stock footage, screenshots |
| Camera (V2) | video | cut | the camera take, usually a PiP with the cutout |
| Screen (V1) | video | cut | the screen recording |
| Voice (A1) | audio | cut | the camera's sound, linked to the picture |
| Music (A2) | audio | follow | the music bed |
| SFX (A3) | audio | follow | sound effects |

Video clips are silent. Sound always lives on audio tracks, linked to its
picture.

### Ripple modes in plain words

- **cut** tracks hold the take (screen, camera, voice). A ripple edit that
  removes time from one of them removes the same time from all of them, so
  the picture and the sound stay in sync.
- **follow** tracks (B-roll, graphics, text, music, SFX) aren't cut. Their
  clips slide along with the take. A music bed or B-roll shot that spans the
  removed time keeps playing from where it started and simply ends that much
  sooner. A clip that sat entirely inside the removed time is removed, with a
  warning.
- **off** tracks stay where they are whatever happens elsewhere.
- A ripple edit made on a follow or off track only moves that track, so
  closing a gap in the B-roll never touches the take.
- Markers move with ripples of the take.
- Locked tracks never move. That can put a take out of sync, so you get a
  warning (and `tighten` refuses until the track is unlocked).

### Linked clips

Clips placed together from one take (camera picture, camera sound, screen)
share a link group. Moves, trims, cuts, slips and speed changes apply to the
whole group unless you pass `"includeLinked": false`. The timeline view shows
the groups as `linked #1`, `linked #2`.

### Transitions

A transition joins two touching clips on one track, or sits at one clip's
head or tail. A transition between two clips is centred on the cut, so both
clips need half its length of spare media beyond the cut (handles). Without
them the command fails and says how much is missing; trim first or use a
shorter transition. On audio tracks every transition is a crossfade.

## Reading the project

`tandem timeline` (MCP `timeline`) is the view to start from:

```
Decision Models: 01:00.000 long, 3840x2160 at 30 fps, revision 7
Tracks top to bottom as the app shows them. cut tracks hold the take and ripple edits cut them together; follow tracks move with them; off tracks stay put.
Clips: ID, start-end on the timeline, length, content [source in-out of the file], then settings that aren't the defaults.

Markers
  00:30.000  section  "Section 2"  mk_s2

V5 Text  trk_text  follow
  clip_txt1  00:02.000-00:05.000     3.000s  text "DECISION MODELS" callout  in popIn

V3 B-roll  trk_broll  follow
  clip_brl1  00:20.000-00:25.000     5.000s  servers.mp4 [00:01.000-00:06.000]

V2 Camera  trk_camera  cut
  clip_cam1  00:00.000-00:30.000    30.000s  take1-camera.mov [00:00.000-00:30.000]  linked #1  layout pipRight  scale 0.5 at 0.87,0.77  cutout  fx dropShadow
    ~ dissolve 0.500s into clip_cam2  tr_dissolve
  clip_cam2  00:30.000-01:00.000    30.000s  take1-camera.mov [00:32.000-01:02.000]  linked #2  layout pipRight  scale 0.5 at 0.87,0.77  cutout  fx dropShadow

A1 Voice  trk_voice  cut
  clip_voc1  00:00.000-00:30.000    30.000s  take1-camera.mov [00:00.000-00:30.000]  linked #1  level -14 LUFS
  clip_voc2  00:30.000-01:00.000    30.000s  take1-camera.mov [00:32.000-01:02.000]  linked #2  level -14 LUFS

A2 Music  trk_music  follow
  clip_mus1  00:00.000-01:00.000  01:00.000  bed.m4a [00:00.000-01:00.000]  gain -31 dB  fade out 2.000s

Media
  med_camera  source/take1-camera.mov  camera  01:10.000  3840x2160 30fps  take take1 +0.500s
  ...
```

Each track line has the track's ID for commands that need one. Transitions
(`~`) sit between the clips they join, and gaps in the take are listed as
`gap`. When most of a track's clips share settings (a PiP camera track's
`layout pipRight, scale 0.5 at 0.87,0.77, cutout, fx dropShadow`), the
track line says them once as `(most clips: ...)`, each clip lists only
what's different, and `not: ...` marks a clip that lacks one of them.

A real edit runs to hundreds of clips, so start with `--summary` (one line
per track with its clip count, span and gaps, plus the markers), then read a
part in full with `--from 1:00 --to 2:00`. `--words` prints what each voice
clip says under it, and `--json` gives the project JSON (tracks keep only the
clips in the range).

- `transcript <clip ID>` gives word timings in timeline time;
  `transcript <media ID>` gives the whole file in file time; with no ID you
  get everything said on the timeline.
- `search "phrase"` gives timeline ranges and the clips that play them. It
  ignores case and punctuation, marks hits a cut runs through as partial,
  and also lists matches in material that was cut out.
- `pauses --min 0.6` lists silences between words in timeline time. Only
  gaps fully covered by transcribed speech count, so a hole in the take or a
  clip still waiting for its transcript is never reported as a pause.
- `media` shows each file's analysis state. Transcripts, loudness, proxies
  and cutout mattes are made in the background; tools that need a
  transcript say which files don't have one yet.
- `frame <time>` renders one frame (MCP returns the image, 1280 px wide by
  default). `clip <start> <end>` renders a 720p review MP4 you can watch.
  Both, and `export`, list what the render shows differently from the
  project, like `Warning: No cutout matte for ...-camera.mov yet, showing the
  full frame.` while the matte is still being made; only lines about what
  plays in the part rendered are shown.

## Assets

Music, sound effects, stickers, icons, logos, fonts and stock footage come
from Mike's asset library, one per user at
`~/Library/Application Support/Tandem/Assets/`, shared with the app's
browser. Every asset records its licence, and every use in a project is
recorded, which is what the description credits are built from.
`docs/ASSETS.md` explains the sources and licences.

- `tandem assets providers` (MCP `assets_providers`) lists the sources and
  whether each works now, with what to fix: a missing key, or an ElevenLabs
  key without the `sound_generation` permission (music still works then).
- `tandem assets search "whoosh" --kind sfx` (`assets_search`) searches the
  library's catalogue: import folders, downloaded and generated assets, the
  starter set and recent provider results. `--online` asks the providers
  too (Noto emoji, Iconify, SVGL logos and Fontsource, plus Pexels, Pixabay
  and Freesound when they have keys), and `--provider noto` limits it to one
  source. Kinds are music, sfx, sticker, overlay, video, image, font, icon,
  logo, lut, title and transition. Asset IDs look like `noto:1f680`,
  `svgl:convex` or `import:sfx-3fa2c1/Whoosh_03.wav`.
- `tandem assets use <id>` (`assets_use`) downloads and normalises the asset
  if needed, copies it into the project's `assets/<kind>/` folder, records
  the use and adds it to the project's media. With `--at 1:23` it's also
  placed on the track for its kind: sound effects on SFX at -15 dB, music on
  Music at -31 dB with a 2 s fade out, stickers, icons and logos on
  Graphics, stock video on B-roll. The edit goes through the app when the app
  has the project open, as one undo step under your name. Fonts are
  installed instead of placed; use their name in a title's style.
- `tandem assets fetch <id>` downloads and normalises without using it.
- `tandem assets credits` (`assets_credits`) prints the credits block for
  the video description from what the project uses now, plus anything to
  sort out before publishing: assets with no licence on record, credits
  without a credit line, subscriptions that must stay active.
- `tandem assets generate sfx "short airy whoosh" --duration 1`
  (`assets_generate`) makes a sound effect (0.5 to 30 s) or music cue (3 to
  600 s) with ElevenLabs. Each take is a paid request, so make one unless
  asked for more; `--variations 3` makes three.
- `tandem assets install-starter` puts the starter set (about 40 animated
  emoji, 30 icons and the tech logos Mike uses) in the catalogue. Each one
  downloads the first time it's used.

`$TANDEM_ASSETS_ROOT` moves the library, and `TANDEM_ASSETS_OFFLINE=1`
keeps it off the network and out of the Keychain (for tests, or a flight).

## Edit command reference

A batch looks like this; `commands` is required and the rest is optional:

```json
{"label": "Tighten the intro", "author": "claude", "expectedRevision": 41, "idempotencyKey": "intro-tighten-1",
 "commands": [
   {"rippleDeleteRange": {"range": {"start": 12.4, "duration": 0.8}}},
   {"blade": {"at": 30}}
 ]}
```

`tandem apply` also takes a bare list of commands, or a single command.
Patches (`updateClip`, `updateTrack`...) are JSON merge patches: send only
the fields to change, nested objects merge, and `null` removes a field.
`tandem schema` prints the full JSON schema.

### Project and tracks

#### updateProject

Changes the project's name or metadata.

```json
{"updateProject": {"patch": {"name": "Decision Models v2", "metadata": {"script": "script.md"}}}}
```

#### updateSettings

Changes the canvas size, frame rate, sample rate, loudness target or true
peak ceiling, or adds alternate formats like the 9:16 short.

```json
{"updateSettings": {"patch": {"loudnessTarget": -14}}}
```

#### addTrack

Adds a track (`kind` is `video` or `audio`). Video tracks go on top unless
`index` says otherwise (0 is the bottom).

```json
{"addTrack": {"kind": "video", "name": "Stickers"}}
```

#### removeTrack

Removes a track and everything on it.

```json
{"removeTrack": {"trackID": "trk_stickers"}}
```

#### moveTrack

Moves a track to another position among tracks of its kind.

```json
{"moveTrack": {"trackID": "trk_stickers", "index": 2}}
```

#### updateTrack

Changes a track's `name`, `muted`, `solo`, `locked`, `hidden`, `targeted`
or `rippleMode` (`cut`, `follow`, `off`).

```json
{"updateTrack": {"trackID": "trk_music", "patch": {"muted": true}}}
```

### Media

#### addMedia

Adds a file to the project (not the timeline). `tandem media --refresh`
usually does this for you by scanning the folder.

```json
{"addMedia": {"item": {"path": "broll/servers.mp4", "kind": "video", "role": "broll", "duration": 12.5, "hasVideo": true}}}
```

#### updateMedia

Changes a media item, for example its role or its colour look (effects
applied to every clip of that file).

```json
{"updateMedia": {"mediaID": "med_screen", "patch": {"role": "screen"}}}
```

#### removeMedia

Removes a media item. Fails while clips still use it.

```json
{"removeMedia": {"mediaID": "med_unused"}}
```

### Placing and removing clips

#### placeMedia

Puts media on the timeline the way the app does when you drag it in: each
file goes to the track for its role (camera to Camera, screen to Screen,
B-roll to B-roll, music to Music), a camera file's sound goes to Voice as a
linked clip, and the files of one take are placed in sync and linked.
`sourceStart` is measured from the start of the take (or the file) and
`duration` defaults to all the media that's left. `mode` is `place` (fails
if the range is taken), `overwrite` or `insert` (pushes later clips right).

```json
{"placeMedia": {"mediaIDs": ["med_camera", "med_screen"], "at": 0}}
```

#### insertClip

Adds one clip to a track: a text title, a solid, a graphic, an adjustment
layer or part of a media file. `content` is one of `{"media": {"mediaID":
...}}`, `{"text": {...}}`, `{"graphic": {"template": ...}}`, `{"solid":
{"color": {...}}}` or `{"adjustment": {}}`.

```json
{"insertClip": {"trackID": "trk_text", "clip": {"content": {"text": {"text": "TIP 1", "preset": "callout"}}, "start": 12, "duration": 3}}}
```

#### removeClips

Removes clips. Without `ripple` they leave a gap (a lift); with `ripple` the
gap closes like Shift-Delete, and on the take that ripples every track.

```json
{"removeClips": {"clipIDs": ["clip_k3f9x2mq"], "ripple": true}}
```

#### rippleDeleteRange

Removes a stretch of time and closes it up: every cut track loses it and
follow tracks move with it. This is the workhorse for tightening pauses and
cutting phrases. The range is `start` plus `duration`, or `start` and
`end`. `trackIDs` limits the cut to those tracks.

```json
{"rippleDeleteRange": {"range": {"start": 12.4, "duration": 0.8}}}
```

#### closeGap

Closes the gap on a track that contains a time. Fails if another cut track
has something in that gap.

```json
{"closeGap": {"trackID": "trk_broll", "at": 27}}
```

#### insertTime

Opens up empty time, pushing everything later to the right (cut tracks
split, follow tracks move).

```json
{"insertTime": {"at": 30, "duration": 2}}
```

#### insertTemplate

Expands a template (a section card, Like and Subscribe, Comment Below) into
linked clips at a time, filling `{{field}}` placeholders from `values`.
Templates come from packs as JSON. Media a template uses must already be in
the project, matched by path.

```json
{"insertTemplate": {"template": {"id": "sectionCard", "name": "Section card", "duration": 3, "fields": [{"key": "title", "label": "Title"}], "clips": [{"track": "Text", "clip": {"content": {"text": {"text": "{{title}}", "preset": "sectionHeader"}}, "duration": 3}}]}, "at": 60, "values": {"title": "CURSOR DOCS"}}}
```

### Cutting and trimming

#### blade

Cuts clips at a time. With `clipIDs` only those clips (and their linked
partners); otherwise every clip under the time on `trackIDs`, or on every
targeted track.

```json
{"blade": {"at": 12.5}}
```

#### trim

Moves a clip edge (`start` or `end`) to a timeline time. With `ripple` the
clip keeps its place and everything after it moves instead.

```json
{"trim": {"clipID": "clip_k3f9x2mq", "edge": "end", "to": 42.2, "ripple": true}}
```

#### roll

Moves the cut between two adjacent clips, trimming both, and the same cut
on linked tracks.

```json
{"roll": {"leftClipID": "clip_a", "rightClipID": "clip_b", "delta": 0.5}}
```

#### slip

Changes which part of the media a clip shows without moving it. `delta` is
media time; negative shows earlier media.

```json
{"slip": {"clipID": "clip_k3f9x2mq", "delta": -1}}
```

#### slide

Moves a clip between its neighbours, trimming them to compensate.

```json
{"slide": {"clipID": "clip_k3f9x2mq", "delta": 2}}
```

#### setSpeed

Changes speed but keeps the same media, so the clip gets shorter or longer.
Linked clips change with it; `ripple` moves later clips to fit.

```json
{"setSpeed": {"clipID": "clip_k3f9x2mq", "speed": 1.5, "ripple": true}}
```

### Moving and editing clips

#### moveClips

Moves clips in time (`delta`) and optionally to another track (clips from
one track only). `mode` is `place` (fails if the destination is taken) or
`overwrite`.

```json
{"moveClips": {"clipIDs": ["clip_k3f9x2mq"], "delta": 5, "toTrackID": "trk_graphics"}}
```

#### updateClip

Changes any clip setting: `video.transform` (position, scale, rotation),
`video.crop`, `video.opacity`, `video.cutout`, `audio.gainDB`,
`audio.fadeIn`, `audio.fadeOut`, `audio.normalizeTo`, `audio.voiceIsolation`,
the text of a title, `enabled`, `name`, `tags`...

```json
{"updateClip": {"clipID": "clip_k3f9x2mq", "patch": {"video": {"opacity": 0.5}}}}
```

#### link

Links clips so they select, move, trim and cut together.

```json
{"link": {"clipIDs": ["clip_a", "clip_b"]}}
```

#### unlink

Takes clips out of their link group.

```json
{"unlink": {"clipIDs": ["clip_a"]}}
```

#### applyLayout

Sets a one-key layout on video clips: `full` (fills the frame), `pipRight`
(50% with the cutout and Filmora's drop shadow, bottom right, Mike's usual
PiP), `pipLeft`, or `split` (camera on the right half, everything else on
the left). Audio clips in the list are skipped.

```json
{"applyLayout": {"clipIDs": ["clip_cam1"], "preset": "pipRight"}}
```

#### zoomToRegion

Zooms a video clip into a rectangle of its source (0...1 from the top
left). Without `at` the zoom is static; with `at` (a timeline time) it
animates there over `duration` (default 0.5 s). Zoom back out later with the
rectangle `{"x": 0, "y": 0, "width": 1, "height": 1}`.

```json
{"zoomToRegion": {"clipID": "clip_scr1", "rect": {"x": 0.5, "y": 0.25, "width": 0.5, "height": 0.5}, "at": 42, "duration": 0.5}}
```

#### setFormatLayout

Places video clips in an alternate output format from
`settings.alternateFormats`, such as the 9:16 short (`portrait`): the `top`
or `bottom` half, or the `full` frame, filled edge to edge with the sides
cropped. `cutout` turns the cutout on or off in that format only (a short
shows the camera with its background). The landscape layout is untouched,
so one edit makes both videos. `tandem short` does this for a whole
project.

```json
{"setFormatLayout": {"clipIDs": ["clip_cam1"], "format": "portrait", "slot": "bottom", "cutout": false}}
```

### Transitions

#### addTransition

Adds a transition: `dissolve`, `fadeToBlack`, `fadeFromBlack`, `push`,
`slide`, `cutSlide`, `wipe` or `zoom` (`direction` for push, slide and
wipe). Leave out `fromClipID` for a transition at the head of `toClipID`,
or `toClipID` for one at the tail of `fromClipID`. `duration` defaults to
Mike's usual length for the type.

```json
{"addTransition": {"trackID": "trk_camera", "transition": {"type": "dissolve", "duration": 0.5, "fromClipID": "clip_a", "toClipID": "clip_b"}}}
```

#### updateTransition

Changes a transition's type, direction or duration.

```json
{"updateTransition": {"transitionID": "tr_x", "patch": {"duration": 0.8}}}
```

#### removeTransition

Removes a transition.

```json
{"removeTransition": {"transitionID": "tr_x"}}
```

### Effects and animation

#### addEffect

Adds an effect to a clip's video or audio effects, depending on the effect.
`tandem effects` lists the types with their parameters and defaults:
`colorAdjust`, `hsl`, `vignette`, `sharpen`, `lut`, `dropShadow`, `border`,
`roundedCorners`, `blur`, `pixelate` and `pitchShift`.

```json
{"addEffect": {"clipID": "clip_cam1", "effect": {"type": "dropShadow", "params": {"opacity": 40}}}}
```

#### updateEffect

Changes an effect's parameters or turns it on or off (`enabled`).

```json
{"updateEffect": {"clipID": "clip_cam1", "effectID": "fx_s", "patch": {"params": {"blur": 8}}}}
```

#### removeEffect

Removes an effect and its animations.

```json
{"removeEffect": {"clipID": "clip_cam1", "effectID": "fx_s"}}
```

#### moveEffect

Moves an effect to another position in the clip's list (effects apply in
order).

```json
{"moveEffect": {"clipID": "clip_cam1", "effectID": "fx_s", "index": 0}}
```

#### setKeyframes

Replaces the keyframes of one parameter: `video.transform.position`,
`video.transform.scale`, `video.transform.rotation`, `video.opacity`,
`video.crop.left` (and top, right, bottom), `audio.gainDB`, or an effect
parameter as `video.effects.<effectID>.<param>`. Keyframe times are seconds
from the clip's start, and move with the clip. An empty list removes the
animation.

```json
{"setKeyframes": {"clipID": "clip_scr1", "parameter": "video.transform.scale", "keyframes": [{"time": 0, "value": 1, "interpolation": "linear"}, {"time": 2, "value": 1.5}]}}
```

### Markers

#### addMarker

Adds a marker. `kind` is `marker`, `section`, `chapter` or `todo`; a
`duration` makes it a range.

```json
{"addMarker": {"marker": {"time": 95, "name": "Section 2", "kind": "section"}}}
```

#### updateMarker

Changes a marker's time, duration, name, kind or note.

```json
{"updateMarker": {"markerID": "mk_x", "patch": {"name": "Intro"}}}
```

#### removeMarker

Removes a marker.

```json
{"removeMarker": {"markerID": "mk_x"}}
```

## Recipes

Each recipe shows the CLI; the MCP tools take the same arguments.

### Tighten pauses

```bash
tandem pauses --min 0.6                      # what's there
tandem tighten --min 0.6 --keep 0.15         # the plan, nothing changes
tandem tighten --min 0.6 --keep 0.15 --apply
tandem clip 0:00 1:00 -o /tmp/review.mp4     # watch the result
tandem undo                                  # if it's too tight
```

Each pause of at least `--min` is shortened to `--keep`, cut from the
middle so half the kept silence stays after the last word and half before
the next one, with the cut edges on frame boundaries. The plan is a batch of
`rippleDeleteRange` commands (latest first, so every range is in the
current timeline's times); `--json` prints it if you'd rather adjust it and
`apply` it yourself. `--from` and `--to` limit it to part of the video. In
MCP: `tighten {"min": 0.6, "keep": 0.15}`, then again with `"apply": true,
"expectedRevision": <the plan's revision>`.

### Caption a short

```bash
tandem captions --from 0:00 --to 1:30                 # the plan, nothing changes
tandem captions --from 0:00 --to 1:30 --apply
tandem frame 0:12 -o /tmp/caption.png --format portrait
```

Captions come from the transcripts: up to three words at a time (`--max-words`),
breaking at sentence ends and pauses, with the word being spoken highlighted
(the `caption` title preset, Tilt Warp with a black outline, which is what
Mike's shorts use). They go on a "Captions" video track that follows ripple
edits, so tightening pauses afterwards keeps them in sync. `--y` moves them:
the default 0.42 sits between the screen and the camera in a 9:16 short;
use about 0.85 for landscape. Run it again over the same range to redo them
(it overwrites what's on the track there).

### Make a short

```bash
tandem short                                   # the plan, nothing changes
tandem short --apply
tandem captions --apply                        # word captions between the halves
tandem frame 0:30 --format portrait -o /tmp/short.png
tandem export --preset short -o ~/Movies/short.mp4
```

The short is an alternate output format of the same project (1080x1920):
screen, B-roll and graphics fill the top half, the camera fills the bottom
half with its background, and full-frame camera moments fill the frame.
Every edit to the project shows up in both videos. To cut the short down
without touching the long one, save a version first and edit that.

### Cut a phrase

```bash
tandem search "as I said before"
```

```
"as I said before" on the timeline, 1 time:
  02:14.320-02:15.980  ...so the model [as I said before] picks the...  clips clip_voc7,clip_cam7
```

Cut that range from the whole take, reaching into the pauses either side so
no breath is left behind (`tandem pauses --from 2:10 --to 2:20` shows them):

```json
{"label": "Cut the repeated phrase", "expectedRevision": 57, "commands": [
  {"rippleDeleteRange": {"range": {"start": 134.2, "end": 136.05}}}
]}
```

Then check it with `tandem clip 2:08 2:20`.

### Put B-roll over a sentence

Find when the sentence is said, and the B-roll file's media ID:

```bash
tandem search "our servers handle the load"
tandem media
```

Place the shot on the B-roll track for exactly that sentence. `sourceStart`
picks where in the B-roll file to start. B-roll is silent unless you pass
`"includeAudio": true`.

```json
{"label": "B-roll over the servers line", "commands": [
  {"placeMedia": {"mediaIDs": ["med_servers"], "at": 134.32, "duration": 4.5, "sourceStart": 2}}
]}
```

If the B-roll track already has something there, add `"mode": "overwrite"`
or name another track with `"videoTrackID"`.

### Add a title

Find the Text track's ID in `tandem timeline` (the `V5 Text trk_...` line)
and insert a text clip:

```json
{"label": "Title for tip 1", "commands": [
  {"insertClip": {"trackID": "trk_text", "clip": {"content": {"text": {"text": "TIP 1", "preset": "callout", "animationIn": "popIn", "animationOut": "fadeOut"}}, "start": 95, "duration": 3}}}
]}
```

Change the words later with
`{"updateClip": {"clipID": "clip_...", "patch": {"content": {"text": {"text": "TIP 2"}}}}}`.

### Add a section card

Section cards and calls to action are templates: a group of text, graphics
and sound effects that go in together, linked. Put the sound effect files
in the project first (`tandem media --refresh`), then insert the template
with its fields filled in:

```json
{"label": "Section card: Cursor docs", "commands": [
  {"insertTemplate": {"at": 180, "values": {"number": "3", "title": "CURSOR DOCS"}, "template": {
    "id": "sectionCard", "name": "Section card", "duration": 3.3,
    "fields": [{"key": "number", "label": "Number", "defaultValue": "1"}, {"key": "title", "label": "Title"}],
    "clips": [
      {"track": "Graphics", "clip": {"content": {"solid": {"color": {"r": 0.1, "g": 0.1, "b": 0.1}}}, "duration": 3.3}},
      {"track": "Text", "offset": 0.2, "clip": {"content": {"text": {"text": "TIP {{number}}", "preset": "label"}}, "duration": 3}},
      {"track": "SFX", "trackKind": "audio", "clip": {"duration": 1, "audio": {"gainDB": -15}}, "mediaPath": "sfx/whoosh.wav"}
    ]}}}
]}
```

### Set the PiP layout

Put the camera in the bottom-right corner with the cutout and shadow, the
way Mike does:

```json
{"label": "Camera to PiP", "commands": [
  {"applyLayout": {"clipIDs": ["clip_cam1", "clip_cam2"], "preset": "pipRight"}}
]}
```

`full` puts it back to full frame for a talking-head section, `pipLeft`
moves it to the other corner when the screen has something important
bottom right, and `split` puts camera and screen side by side. To fine-tune
the corner, patch the transform:
`{"updateClip": {"clipID": "clip_cam1", "patch": {"video": {"transform": {"position": {"x": 0.86, "y": 0.76}}}}}}`.

### Zoom into the screen recording

Zoom the screen clip into the top-right quarter at 1:12 and back out at
1:20:

```json
{"label": "Zoom on the settings panel", "commands": [
  {"zoomToRegion": {"clipID": "clip_scr2", "rect": {"x": 0.5, "y": 0, "width": 0.5, "height": 0.5}, "at": 72, "duration": 0.5}},
  {"zoomToRegion": {"clipID": "clip_scr2", "rect": {"x": 0, "y": 0, "width": 1, "height": 1}, "at": 80, "duration": 0.5}}
]}
```

### Export a review clip

```bash
tandem frame 2:14.5 -o /tmp/frame.png        # one frame
tandem clip 2:00 2:30 -o /tmp/review.mp4     # 720p review render
tandem export --preset youtube4k             # the full video, loudness matched
```

`clip` defaults to `exports/review <start>-<end>.mp4` in the project folder
and `export` to `exports/<name> r<revision>.mp4`. In MCP, `frame` returns
the picture directly, so you can look at the result of an edit.

### Put a whoosh on every push transition

Find the cut each push transition sits on (the end of its outgoing clip,
or the start of its incoming one), pick a whoosh, add it to the project
once, then place it at every cut in one batch:

```bash
tandem timeline --json | jq -c '[.project.videoTracks[] | . as $t | .transitions[]
  | select(.type == "push") | . as $x | $t.clips[]
  | if $x.fromClipID then select(.id == $x.fromClipID) | .start + .duration
    else select(.id == $x.toClipID) | .start end | . * 1000 | round / 1000] | unique'
# [106.932,136.59,242.9,...]
tandem assets search whoosh --kind sfx          # or --online, or generate one
tandem assets use import:sfx-3fa2c1/Whoosh_03.wav   # adds it to the media, prints its media ID
```

Start each whoosh about 0.3 s before its cut so it peaks on the cut:

```json
{"label": "Whooshes on the pushes", "commands": [
  {"placeMedia": {"mediaIDs": ["med_w4k2p8zq"], "at": 106.632}},
  {"placeMedia": {"mediaIDs": ["med_w4k2p8zq"], "at": 136.29}},
  {"placeMedia": {"mediaIDs": ["med_w4k2p8zq"], "at": 242.6}}
]}
```

`placeMedia` puts each one on SFX at the usual -15 dB. When another sound is
already there, add `"mode": "overwrite"` or name a free audio track with
`"audioTrackID"`. For a handful, `tandem assets use <id> --at <time>` once
per cut does the same, one undo step each.

### Credits for the description

```bash
tandem assets credits
```

prints the block to paste into the YouTube description, for example:

```
Paste into the description:

Credits
Animated Noto Emoji by Google, CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/)

Before publishing:
  - No licence on record for "Glitch Hit 02". Add a tandem-licence.json to their import folder, or replace them.
```

It counts the assets still in the project's media, so run it last, after
removing media the cut no longer uses. Sort out everything under "Before
publishing" first. `--optional` adds courtesy credits nobody requires
(Pexels creators).

### Work alongside Mike

- Read before you write: take the revision from `timeline` or `status` and
  pass it as `expectedRevision`. On `staleRevision`, read again.
- Try a big batch with `dryRun` first.
- Give retried batches an `idempotencyKey`.
- Undo with `expectedRevision` so you only undo your own edit.
- `tandem watch --once` (MCP `watch`) waits until the project changes, for
  example after asking Mike to fix something in the app. `tandem watch`
  prints every change as it happens.

## Operations

| Operation | CLI | HTTP | MCP tool |
| --- | --- | --- | --- |
| status | `tandem status` | `POST /v1/status` | `status` |
| media | `tandem media [--refresh]` | `POST /v1/media {"refresh": true}` | `media` |
| timeline | `tandem timeline [--summary] [--from] [--to] [--words] [--json]` | `POST /v1/timeline {"summary", "from", "to", "words", "format"}` | `timeline` |
| transcript | `tandem transcript [<id>]` | `POST /v1/transcript {"id"}` | `transcript` |
| search | `tandem search "<phrase>"` | `POST /v1/search {"phrase"}` | `search` |
| pauses | `tandem pauses [--min]` | `POST /v1/pauses {"min"}` | `pauses` |
| tighten | `tandem tighten [--min] [--keep] [--apply]` | `POST /v1/tighten {"min", "keep", "apply"}` | `tighten` |
| captions | `tandem captions [--from] [--to] [--max-words] [--y] [--apply]` | `POST /v1/captions {"from", "to", "words", "y", "apply"}` | `captions` |
| short | `tandem short [--apply]` | `POST /v1/short {"apply"}` | `short` |
| apply | `tandem apply <file or ->` | `POST /v1/apply <batch>` | `apply` |
| undo, redo | `tandem undo`, `tandem redo` | `POST /v1/undo`, `/v1/redo` | `undo`, `redo` |
| history | `tandem history` | `POST /v1/history` | `history` |
| validate | `tandem validate` | `POST /v1/validate` | `validate` |
| frame | `tandem frame <time> -o out.png` | `POST /v1/frame {"time", "output"}` | `frame` (image) |
| screenshot | | `POST /v1/screenshot` | `screenshot` (app only) |
| clip | `tandem clip <start> <end> -o out.mp4` | `POST /v1/clip {"start", "end"}` | `clip` |
| export | `tandem export [--preset] -o out.mp4` | `POST /v1/export {"preset", "output"}` | `export` |
| loudness | `tandem loudness` | `POST /v1/loudness` | `loudness` |
| watch | `tandem watch [--once]` | `GET /v1/watch` (events), `POST /v1/watch` (wait) | `watch` |
| effects | `tandem effects` | `POST /v1/effects` | `effects` |

Output paths given to the API are absolute or relative to the project
folder; the CLI makes them absolute from where you run it.

The asset library isn't a project operation, so it has no HTTP endpoint;
the CLI and MCP open the library themselves, and only `use` and `credits`
reach the project (through the app's API when it's open).

| Asset operation | CLI | MCP tool |
| --- | --- | --- |
| providers | `tandem assets providers` | `assets_providers` |
| search | `tandem assets search "<text>" [--kind] [--provider] [--online]` | `assets_search` |
| fetch | `tandem assets fetch <id>` | |
| use | `tandem assets use <id> [--at] [--duration]` | `assets_use` |
| credits | `tandem assets credits [--optional]` | `assets_credits` |
| generate | `tandem assets generate sfx or music "<prompt>"` | `assets_generate` |
| install-starter | `tandem assets install-starter` | |

## Troubleshooting

- **"is open in the Tandem app, but the app isn't serving its API"**: the
  app has the project open but no API. Restart or update the app.
- **"busy in another tandem command"**: another command has the project
  open right now. Commands wait up to 15 seconds for it before giving up.
- **"isn't built yet, so this doesn't work in this version of Tandem"**:
  rendering or media analysis isn't in this build.
- **No pauses or search results**: check `tandem media`; transcripts are
  made in the background after files are added.
- **"Nothing to undo" after editing with the app closed**: headless undo
  history only lasts while nobody else edits the project. `tandem history`
  shows what can be undone.
- **"ElevenLabs refused: ... missing the permission sound_generation"**: the
  key can make music but not sound effects. Mike turns the permission on
  for the key in ElevenLabs; `tandem assets providers` says when it's fixed.
- **"No asset ... in the library"**: search for it first (with `--online`
  for provider assets), then use the ID the search gives.
