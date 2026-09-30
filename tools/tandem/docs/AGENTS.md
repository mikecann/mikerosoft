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
tandem status                      revision, length, who has it open, jobs, missing fonts
tandem timeline [--summary] [--from T] [--to T] [--words] [--json]
tandem media [--refresh]           files, clip counts, analysis status
tandem transcript [<clip or media id>] [--from T] [--to T]
tandem search "<phrase>"           where a phrase is said
tandem pauses [--min 0.6]          silences between words
tandem tighten [--min 0.6] [--keep 0.15] [--apply]
tandem captions [--from T] [--to T] [--max-words 3] [--y 0.42] [--apply]
tandem short [--apply]             lay out a 9:16 short from the same edit
tandem cards [--insert] [--no-sounds] [--apply]   a section card at every section marker
tandem apply <batch.json | ->      [--dry-run] [--expect N] [--label L] [--key K]
tandem undo [--expect N]    tandem redo    tandem history    tandem validate
tandem frame <time> [-o out.png]   tandem clip <start> <end> [-o out.mp4]
tandem export [--preset <name>] [-o out.mp4] [--from T] [--to T] [--format <id>]
tandem loudness    tandem effects    tandem schema    tandem watch [--once]
tandem archive [<project>] [--to <folder>] [--with-cache] [--dry-run]
tandem relink [--search <folder>]... [--dry-run]    find missing media
tandem new <path.tandem>           tandem serve    tandem mcp
tandem import filmora <file.wfp> [--out DIR] [--keep-levels]   a Filmora project as a .tandem
tandem import edl [edl.json] --recipe decision-models [--out DIR]
tandem import compare <a.tandem> <b.tandem>      how two cuts of one take differ
tandem assets providers                          asset sources and what to fix
tandem assets search "<text>" [--kind sfx] [--provider id] [--online] [--limit n]
tandem assets use <id> [--at T] [--duration T]   copy into the project, add, place
tandem assets fetch <id>    tandem assets credits [--optional]
tandem assets generate sfx|music "<prompt>" [--duration s]    tandem assets install-starter
tandem segments list                             saved segments in the shared library
tandem segments save "<name>" --clips <id,id> | --from T --to T [--field <clip>=<label>]... [--replace]
tandem segments insert "<name>" --at T [--value key=text]... [--mode overwrite]
```

`tandem help <command>` explains each one.

Imports write `<out>/<name>/<name>.tandem` with a report beside it
(`<name>.import.txt` for people, `.import.json` for agents) listing anything
that couldn't be carried over. Filmora media paths saved on another Mac are
fixed with `--rewrite /Users/old/=/Users/new/`, and moved files are found
with `--search <folder>`. A Filmora import normalises speech (the camera's
sound and the Voice tracks) to the project's speech level with no gain, the
way placing does, instead of copying Filmora's gains; music and sound
effects keep their Filmora volume. `--keep-levels` keeps Filmora's own
levels: its Auto Normalization becomes `normalizeTo: -24` (where Filmora
levels, on Tandem's meter) with the clip's gain on top.

### What a new project finds

`tandem new` adds every media file in the folder (as `tandem media
--refresh` does later) and gives each a role from its name and folder:
record-it's `-camera` and `-screen` files, then folders like `music/`,
`sfx/`, `broll/`, `graphics/` and `stickers/`. A video nothing names, like a
phone's `IMG_0151.MOV`, becomes the camera take when it's a recording with
a voice and a face: shot by a phone or camera (its metadata names it) or
sitting in `source/`, with speech in its sound and a face in its frames. A
render of an edit has both too, so one anywhere else in the folder stays
`other`. Only files new to the project get a role this way. `tandem new`
says which file it took for the camera, why, and how to change it:

```
Added 16 media files from the folder.
13 are Live Photos: the still is the media item, with its motion clip kept on it (livePhotoVideo) rather than added on its own.
Camera take: source/IMG_0151.MOV (med_yccfihfs), an Apple iPhone XS Max video with speech and a face in it.
Not the camera? tandem apply '{"updateMedia": {"mediaID": "med_yccfihfs", "patch": {"role": "other"}}}'
```

A Live Photo exported from Photos is a still and a movie of a few seconds
with the same name (`IMG_0130.HEIC`, `IMG_0130.mov`). The still is the
media item and keeps the movie's path in `livePhotoVideo`; the movie isn't
media of its own. `tandem media` shows it as `Live Photo, motion clip
IMG_0130.mov`. Folder refreshes, the app's folder watcher and files dropped
on the app all pair them the same way. A movie a project already had as
media stays as it is. Archiving, relink and segments take the movie along
with its still.

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
`transcript`, `search`, `pauses`, `tighten`, `captions`, `short`, `cards`, `apply`, `undo`, `redo`,
`history`, `validate`, `frame`, `screenshot`, `clip`, `export`, `archive`,
`relink`, `loudness`, `watch` and `effects`, plus the asset library's `assets_search`,
`assets_use`, `assets_credits`, `assets_generate` and `assets_providers`,
and the saved segments' `segments_list`, `segments_save` and
`segments_insert`.
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
returns the first result instead of applying it twice. An `interrupted`
error means the app went away (quit or crashed) after it got the call but
before it answered, so an edit may have been applied: check `tandem
history` before sending it again.

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
head or tail. A transition between two clips is centred on the cut, so each
clip plays half its length past the cut. Where a clip has no frames there
(its file used to the last frame, or from the first) that edge frame holds
for the rest, as in Premiere and Filmora, and the edit's warnings say how
long; trim the clip for real motion instead. On audio tracks every
transition is a crossfade, and sound past a file's ends is silence.

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
  clip_voc1  00:00.000-00:30.000    30.000s  take1-camera.mov [00:00.000-00:30.000]  linked #1  level -20 LUFS
  clip_voc2  00:30.000-01:00.000    30.000s  take1-camera.mov [00:32.000-01:02.000]  linked #2  level -20 LUFS

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
- Word times are trimmed to the voice. SpeechAnalyzer times its words end
  to end, so each pause hides inside a word; Tandem pulls every word in to
  where the take's waveform is over its noise floor (about what ffmpeg's
  silencedetect hears at -32 dB on a phone take) when it reads the
  transcript, including transcripts made before it did.
- A word a cut runs through shows once, on the side where most of it
  plays, and a word with less than half of it left doesn't show: it was
  cut. Captions, `pauses`, `tighten`, `search`, `transcript` and `timeline
  --words` all follow this, and so does the app's transcript lane, so
  cutting a pause never doubles a word and cutting out a stumble takes its
  words with it.
- `search "phrase"` gives timeline ranges and the clips that play them. It
  ignores case and punctuation, marks hits a cut runs through as partial
  (one hit for each side, covering the phrase's words there), and also
  lists matches in material that was cut out.
- `pauses --min 0.6` lists the gaps between words in timeline time. Only
  gaps fully covered by transcribed speech count, so a hole in the take or a
  clip still waiting for its transcript is never reported as a pause. A
  breath, click or "um" between two words (SpeechAnalyzer leaves ums out)
  is part of the pause, so `tighten` cuts it with the silence.
- `media` shows each file's analysis state. Transcripts, loudness, proxies
  and cutout mattes are made in the background; tools that need a
  transcript say which files don't have one yet.
- `frame <time>` renders one frame (MCP returns the image, 1280 px wide by
  default). `clip <start> <end>` renders a 720p review MP4 you can watch.
  Both, and `export`, list what the render shows differently from the
  project, like `Warning: No cutout matte for ...-camera.mov yet, showing the
  full frame.` while the matte is still being made; only lines about what
  plays in the part rendered are shown.
- Titles in a font this Mac doesn't have are drawn in SF Pro, and never
  quietly: `frame`, `clip`, `export`, `captions`, `status` and `validate`
  all say so with the fix, like `Tilt Warp, the caption preset's font, isn't
  installed, so 42 text clips are drawn in SF Pro instead. Install it with:
  tandem assets use fontsource:tilt-warp`.

## Assets

Music, sound effects, stickers, icons, logos, fonts and stock footage come
from Mike's asset library, one per user at
`~/Library/Application Support/Tandem/Assets/`, shared with the app's
browser. Every asset records its licence, and every use in a project is
recorded, which is what the description credits are built from.
`docs/ASSETS.md` explains the sources and licences.

Mike's own reusable things live in his **shared library**, the folder
`~/Movies/Tandem Library` (Stickers, Graphics, Sound effects, Music, Looks,
Fonts, Segments). Its files are the `shared` source, with IDs that are
their path in the folder: `shared:Stickers/Star.mov`, `shared:Sound
effects/Whoosh.wav`. Unlike every other source, a shared asset isn't copied
into the project when it's used: the project refers to the library's file
where it is (absolute path), so a sticker Mike improves in the library
improves every video that uses it. Archiving the project copies those files
in (see [Archive a finished video](#archive-a-finished-video)).
`tandem assets search --provider shared` lists them. The app watches the
folder, and the CLI and MCP look at it again before they search (only
changed files are read), so a file dropped in is found straight away.

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
  if needed, copies it into the project's `assets/<kind>/` folder (a
  `shared:` asset is used where it is instead, and the result says
  `referencedInPlace`), records the use and adds it to the project's media. With `--at 1:23` it's also
  placed on the track for its kind: sound effects on SFX at -15 dB, music on
  Music at -31 dB with a 2 s fade out, stickers, icons and logos on
  Graphics, stock video on B-roll. The edit goes through the app when the app
  has the project open, as one undo step under your name. Fonts are
  installed instead of placed, into the project's `assets/font/` (a shared
  library font stays in the library, where every render finds it, until
  the project is archived); use their name in a title's style. When the
  app has the project open it has the font straight away too (the output
  says so), with no restart. A
  `fontsource:<name>` ID works without searching first, so the fix a
  missing-font warning gives can be run as it is.
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
`$TANDEM_LIBRARY` moves the shared library for one command; with
`$TANDEM_ASSETS_ROOT` set and no `$TANDEM_LIBRARY`, the shared library is
`Tandem Library` inside that root, so tests never touch the real one.

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

Changes the canvas size, frame rate, sample rate, the master's loudness
target (`loudnessTarget`, -14 LUFS) or true peak ceiling (-1 dBTP), the
speech level (`speechLoudness`, -20 LUFS, between -40 and -10), or adds
alternate formats like the 9:16 short. Changing the speech level moves every
clip normalised to the old level to the new one; clips with a level of
their own keep it.

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

Sound gets Mike's levels: speech (a camera's sound, files with no clearer
role such as a rendered intro, and anything placed on a take track like
Voice) is normalised to the project's speech level with no gain, music gets
-31 dB with a 2 s fade out, and sound effects -15 dB.

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

`{"graphic": {"template": "sectionCard", "props": {...}}}` is Mike's section
card, drawn by Tandem ([Add a section card](#add-a-section-card)); other
graphic templates aren't rendered yet.

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

Expands a template (a section card, Like and Subscribe, Comment Below, a
saved segment) into linked clips at a time, filling `{{field}}`
placeholders in text clips and a graphic's text props from `values`.
Templates come from packs as JSON. Media a template uses is matched by
path (`mediaPath`); a clip that carries its media item under `media` adds
it when the project has nothing at that path yet, and reuses what's there
otherwise. Saved segments carry theirs, which is how `tandem segments
insert` works, and so does the Section card tile for its whooshes; without
one, the file must already be in the project. `transitions` joins its
clips by their place in `clips` (`{"from": 0, "to": 1, "type":
"dissolve"}`, or only `to` for a fade in at a clip's head).

```json
{"insertTemplate": {"template": {"id": "sectionCard", "name": "Section card", "duration": 3, "fields": [{"key": "title", "label": "Title"}], "clips": [{"track": "Text", "clip": {"content": {"text": {"text": "{{title}}", "preset": "sectionHeader"}}, "duration": 3}}]}, "at": 60, "values": {"title": "CURSOR DOCS"}}}
```

A clip that carries its file:

```json
{"insertTemplate": {"template": {"id": "segment:Sting", "name": "Sting", "duration": 1.2, "clips": [{"track": "SFX", "trackKind": "audio", "clip": {"duration": 1.2, "audio": {"gainDB": -15}}, "mediaPath": "/Users/m5-mike/Movies/Tandem Library/Segments/Sting/sting.wav", "media": {"path": "sting.wav", "kind": "audio", "role": "sfx", "duration": 1.2, "hasAudio": true}}]}, "at": 42, "mode": "overwrite"}}
```

#### addSectionCards

Puts a numbered section card at every section marker after 0:00 (a marker
at the very start is the cold open, which gets none), or at `markerIDs`
(any kind). Cards are numbered in time order (`01`, `02`...), `total` is
the count, the title is the marker's name and the subtitle its note. Each
card starts just early enough to hide the whole frame from its marker on,
so the cut between sections is never seen, and is as long as its words need
to be read (1.4 s for the wipes and 0.8 s to take it in, then the title,
subtitle and kicker at 15 characters a second, from 4 s to 7 s) unless
`duration` sets one length for all. Leave `kicker` off unless Mike asks for
one: he prefers the number alone, which reads faster. A section card already over a marker is renumbered (and gets
`kicker` if you pass one) but keeps its own words, colours, length and
sounds, so run it again after adding a section.

`mode` `overwrite` (the default) lays the cards over the timeline on
Graphics (`trackID` for another video track). `insert` also makes room at
each marker, so the card is a pause and its wipes show the last shot of one
section and the first of the next; the whole take moves. `soundIn` and
`soundOut` put a sound on SFX (or SFX 2... where SFX is taken) for each
sweep, linked to its card: a media item already in the project, its gain
(default -15 dB) and `offset`, seconds after its sweep starts (default 0.2
in, 0 out). `tandem cards` fills them in with the section card whooshes
from the asset library, levelled for the project's speech.

```json
{"addSectionCards": {"soundIn": {"mediaID": "med_swishin", "gainDB": -5.4, "offset": 0}, "soundOut": {"mediaID": "med_swishout", "gainDB": -8.3}}}
```

#### fitSectionCards

Makes section cards as long as their words need, like Fit to text in the
app: every card, or `clipIDs`. Each keeps its start and its end moves
(nothing ripples, so a longer card covers a little more of the section it
opens), and its whoosh out moves with its sweep out. Cards that fit already
are left alone. Use it after changing a card's words, clearing its kicker,
or on cards made before the lengths grew (they used to be 3.2 s).

```json
{"fitSectionCards": {}}
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

`audio.normalizeTo` levels the clip from its file's measured loudness (the
target minus the measurement, at most 30 dB either way) and `audio.gainDB`
is added after it: normalised to -20 LUFS with `gainDB` 2, a clip plays at
about -18. `null` stops normalising.

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
PiP), `pipLeft`, `split` (camera on the right half, everything else on
the left), or `fill` (covers the whole frame and crops the edges, so a
landscape photo fills a 9:16 short). Audio clips in the list are skipped.

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

#### addMotion

A slow zoom or pan over the whole of each clip, the Ken Burns effect, for
stills and photos: `zoomIn`, `zoomOut`, `panLeft`, `panRight`, `panUp`,
`panDown`. It starts from the clip's current placement, so in a short apply
the `fill` layout first. `amount` is how much bigger the zoomed end is
(default 1.12, a gentle push). Pans travel across whatever part of the photo
overflows the frame. It replaces the clip's position and scale animation.

```json
{"addMotion": {"clipIDs": ["clip_photo1"], "style": "zoomIn", "amount": 1.15}}
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
`colorAdjust`, `colorWheels`, `hsl`, `vignette`, `sharpen`, `lut`,
`dropShadow`, `border`, `roundedCorners`, `blur`, `pixelate` and
`pitchShift`. [Grade the camera take](#grade-the-camera-take) has how the
colour ones fit together.

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

### Sound

#### normalizeSpeech

Sets every speech clip to the project's speech level (`speechLoudness`,
-20 LUFS unless changed) and clears its gain, as one undo step. Speech is a
camera's sound, a file with no clearer role, or anything on a take track
like Voice (an audio track whose ripple mode is `cut`, muted or not). Music
and sound effects keep their gains; fades, voice isolation, effects and gain
keyframes stay; locked tracks are left alone with a warning.

```json
{"normalizeSpeech": {}}
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
the next one, with the cut edges on frame boundaries. Word edges come from
the voice, so a pause is the real gap between words (breaths and clicks in
it included), not what's left between the transcript's stretched word
times. The plan is a batch of
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
(it overwrites what's on the track there). After cutting pauses or
stumbles, a word shows once, on the side of the cut where most of it plays,
and words that were cut out don't show.

Each caption stores the preset, its words and only what you passed (`--y`
is its position), so the preset decides the look and a later change to it
reaches every caption. Tilt Warp doesn't come with macOS: the first time
captions are applied, Tandem installs it from Fontsource into the project's
`assets/font/` (the output says so), and the app picks it up. If that can't
happen (offline), the captions still go in and the output says what to run.
To restyle them, patch the captions' `style` (see Add a title).

### Make a short

A short is 1080x1920, and there are two ways to make one.
`tandem export --preset short` renders either.

**Cut from a landscape video.** The short is an alternate output format
of the same project (1080x1920):

```bash
tandem short                                   # the plan, nothing changes
tandem short --apply
tandem captions --apply                        # word captions between the halves
tandem frame 0:30 --format portrait -o /tmp/short.png
tandem export --preset short -o ~/Movies/short.mp4
```

Screen, B-roll and graphics fill the top half, the camera fills the bottom
half with its background, and full-frame camera moments fill the frame.
Every edit to the project shows up in both videos. To cut the short down
without touching the long one, save a version first and edit that. The
landscape video still exports with plain `tandem export` (YouTube 4K for a
4K canvas).

**Made portrait from the start**, for a short that isn't cut from a long
video (phone footage, photos). The canvas is the short, so there's no
portrait format and no `tandem short` step (it refuses, as there's
nothing to lay out):

```bash
tandem new "Workbench.tandem" --portrait       # a 1080x1920 canvas
tandem captions --apply
tandem frame 0:30 -o /tmp/short.png
tandem export --preset short                   # exports/Workbench r<revision>.mp4
```

The `fill` layout makes a landscape photo or clip cover the frame. Presets
keep the canvas's shape, so plain `tandem export` and `--preset
youtube1080` make the same 1080x1920 H.264 at 20 Mbps as `--preset short`,
and `--preset youtube4k` upscales to 2160x3840 with a warning. Every export
prints the size, codec and bitrate it used; `tandem help export` has the
presets.

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

The preset gives the look. A clip's `style` holds only what it changes
(`font`, `size`, `weight`, `color`, `strokeColor`, `strokeWidth`,
`backgroundColor`, `alignment`, `uppercase`, `shadow`, `lineSpacing`), and
each field that's there wins over the preset, even `false` or `0`. So a URL
on a label stays lower case, and a callout can lose its shadow and outline:

```json
{"label": "Plain end card", "commands": [
  {"updateClip": {"clipID": "clip_url", "patch": {"content": {"text": {"style": {"uppercase": false, "strokeWidth": 0, "shadow": false}}}}}}
]}
```

`null` for a field in a patch takes it back to the preset's. A
`backgroundColor` with `"a": 0` switches off a preset's box, and
`"animationIn": "none"` (or `animationOut`) its animation. `tandem timeline`
lists what each title sets itself (`style uppercase=false shadow=false`).
The app's Text inspector shows the values the title is drawn with, marks the
ones the clip sets itself in amber, and has a button beside each that goes
back to the preset's.

### Add a section card

Mike's section card is one clip, the built-in `sectionCard` graphic, about
three seconds between the cold open, the intro and each section. Convex's
yellow, red and purple bands sweep across to wipe it in; the dark card holds
a number chip, the title (Anton, upper case) with a yellow text cursor
blinking after its last letter, a letter-spaced subtitle and progress bars
(a bar for each section up to six, then one bar in proportion with a count
like `3 / 14`); and the bands sweep across again to wipe it out, showing the
next shot. It's as long as its words need to be read, from 4 s for a short
title and subtitle to 7 s: a longer card holds longer and the wipes stay the
same.

The usual way is a card at every section marker. Mark where each section
starts (`addMarker` with `"kind": "section"`, or a marker's Kind menu in the
app): the marker's name is the card's title and its note, if it has one,
the subtitle. Then:

```bash
tandem cards                              # the plan: numbers, titles, where each card goes
tandem cards --apply                      # just the number in the chip, as Mike likes
tandem frame 0:33 -o /tmp/card.png        # look at one
```

The cards go on Graphics, each starting 0.43 s before its marker so the
card hides the whole frame from the marker on, and each as long as its
words need: 1.4 s for the wipes and 0.8 s to take it in, then the title,
subtitle and kicker read at 15 characters a second (a little slower than
Netflix's 17 for subtitles: Mike found cards at 17 a bit quick), rounded up
to a tenth of a second, at least 4 s and at most 7. `--duration` makes them
all one length. Mike prefers no kicker (`SECTION 1 OF 9` beside the number):
only pass `--kicker` when he asks. The section keeps playing
under it (Mike's voice too). With `--insert` each marker gets room instead:
the take moves on by the card's hold, so the card is a pause and its wipes
show the last shot of one section and the first of the next. A marker at
0:00 marks the cold open and gets no card. Run `tandem cards` again after
adding or moving a section: cards already at a marker are renumbered and
keep their words. `--kicker Tip` suits a list video. It's one undo step,
and in the app it's Timeline > Add section cards at section markers
(Option-M).

A soft whoosh goes with each sweep: two airy swishes made for the card with
ElevenLabs, kept in the asset library (docs/ASSETS.md). `tandem cards
--apply` copies them into the project's `assets/sfx/` and puts them on SFX,
linked to their card: one as the card starts, one as the out sweep starts,
0.88 s before the end. Their gains (-5.4 and -8.3 dB) put their loudest
moment 15 LU under speech at -20 LUFS, where Mike's own swipes sit; in a
project whose speech plays elsewhere they move with it (an imported edit at
-28.7 gets -14.1 and -17). A Mac whose library doesn't have them makes
silent cards and says so; `--no-sounds` leaves them out.

One card by hand, anywhere:

```json
{"label": "Section card: Results", "commands": [
  {"insertClip": {"trackID": "trk_graphics", "clip": {"content": {"graphic": {"template": "sectionCard", "props": {"number": "02", "title": "Results", "subtitle": "Finally!", "total": 3}}}, "start": 95, "duration": 4}}}
]}
```

Props: `title`, `subtitle`, `number` (what the chip says; a number is
written `02`), `total` (how many sections, for the progress bars; 0 hides
them), `kicker` (`Section` or `Tip`, shown as `SECTION 2 OF 3` beside the
chip; off by default, and Mike prefers it off), `cursor` (`false` turns off the cursor after the title; it's on by
default), and the colours `accent` (the first band, the chip, the subtitle,
the lit bars and the cursor), `band2`, `band3` and `background`, as
`{"r", "g", "b"}` or a hex string like `"#F3B01C"`. A missing word leaves
that part out; colours default to Convex's. Change them later with a patch, for example
`{"updateClip": {"clipID": "clip_...", "patch": {"content": {"graphic": {"props": {"subtitle": "Let's keep it fair"}}}}}}`
(`null` removes one). `tandem frame` shows the result. A card added by hand
is as long as you make it. After changing its words, the Video tab's Fit to
text sets the length they need, trimming the card's end and moving its
whoosh out with the wipe out; by hand that's a `trim` of its end and a
`moveClips` of the whoosh by the same amount.

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

### Grade the camera take

Mike grades a camera take once, on the file's look (`MediaItem.look`), so
every clip from it gets the same grade; the Colour tab calls that the whole
take. A clip's own colour effects go on top of it, for one shot that needs
more, and they can animate like any effect parameter
(`video.effects.<effectID>.<param>`). The look can't.

The Colour tab shows a grade as fixed sections, each backed by one effect:

| Section | Effect | Parameters |
| --- | --- | --- |
| Light | `colorAdjust` | `exposure` (stops), `contrast`, `highlights`, `shadows`, `blackLevel` |
| Colour | `colorAdjust` | `temperature`, `tint`, `saturation`, `vibrance` |
| Colour wheels | `colorWheels` | `shadows`, `midtones` and `highlights`, each with `Hue`, `Amount` and `Brightness` (`shadowsHue`...) |
| Colour mixer | `hsl` | `red`, `orange`, `yellow`, `green`, `aqua`, `blue`, `purple` and `magenta`, each with `Hue`, `Saturation` and `Luminance` (`redSaturation`...) |
| Vignette | `vignette` | `amount`, `size`, `feather` |
| Sharpen | `sharpen` | `amount` |
| LUT | `lut` | `path`, `intensity` |

Write a grade the way the tab reads it: one effect of each type, with the
Light and Colour values in the same `colorAdjust`, as Filmora imports have
them. A section switched off is its effect turned off, so when Mike turns
Light off while Colour has values the tab splits them into two
`colorAdjust` effects, Light's first; a section that's reset loses its
effect (or, when it shares one, its values). Anything the tab can't place,
like a second `hsl`, shows after the sections as it is.

`colorWheels` grades like lift, gamma and gain: the shadows wheel moves
black and leaves white alone, highlights the other way round, and midtones
leaves both. A wheel's hue says which colour it pushes towards (0 red, 60
yellow, 120 green, 180 cyan, 240 blue, 300 magenta, the same degrees as the
mixer's ranges) and its amount how far: 10 to 25 is a normal grade, 100 is
strong, and the hue does nothing while the amount is 0. A wheel changes the
colour of its range, not its brightness; that's what the wheel's brightness
(-100 to 100) is for. Teal shadows and warm highlights, on top of Mike's
usual grade:

```json
{"label": "Grade the camera", "commands": [
  {"updateMedia": {"mediaID": "med_camera", "patch": {"look": [
    {"type": "colorAdjust", "params": {"contrast": 25, "blackLevel": -7, "temperature": -3}},
    {"type": "colorWheels", "params": {"shadowsHue": 200, "shadowsAmount": 12, "highlightsHue": 35, "highlightsAmount": 10}},
    {"type": "hsl", "params": {"redSaturation": -8, "orangeSaturation": -8}},
    {"type": "vignette", "params": {"amount": -30}},
    {"type": "sharpen", "params": {"amount": 3}}
  ]}}}
]}
```

`look` is replaced as a whole, so read it first (`tandem timeline --json`,
under `media`) and send it back with your change. Check the result with
`tandem frame`.

### Zoom into the screen recording

Zoom the screen clip into the top-right quarter at 1:12 and back out at
1:20:

```json
{"label": "Zoom on the settings panel", "commands": [
  {"zoomToRegion": {"clipID": "clip_scr2", "rect": {"x": 0.5, "y": 0, "width": 0.5, "height": 0.5}, "at": 72, "duration": 0.5}},
  {"zoomToRegion": {"clipID": "clip_scr2", "rect": {"x": 0, "y": 0, "width": 1, "height": 1}, "at": 80, "duration": 0.5}}
]}
```

### Level the voice

Speech is levelled per take to the project's speech level, -20 LUFS, and
export brings the whole mix to -14 LUFS with true peaks under -1 dBTP. So
the speech level sets how the voice sits against the music and sound
effects (and how loud the app plays), not how loud the video is. Placing
media levels new speech by itself; a project imported with its own gains,
or made before the speech level existed, gets there with one command:

```bash
tandem loudness                              # each file's loudness, each track's levels
tandem apply - <<< '{"normalizeSpeech": {}}'
tandem loudness                              # "Speech is levelled to -20.0 LUFS" and no stragglers
```

To move the voice for the whole video, change the level (clips normalised
to the old level follow it), then check a review clip:

```json
{"label": "Voice a little louder", "commands": [
  {"updateSettings": {"patch": {"speechLoudness": -18}}}
]}
```

A single clip can still differ: `{"updateClip": {"clipID": "clip_voc7",
"patch": {"audio": {"gainDB": 2}}}}` plays it 2 dB over the rest.

### Export a review clip

```bash
tandem frame 2:14.5 -o /tmp/frame.png        # one frame
tandem clip 2:00 2:30 -o /tmp/review.mp4     # 720p review render
tandem export                                # the full video, loudness matched
```

Plain `export` picks the preset that fits the canvas: YouTube 1080p for a
canvas 1080 pixels or less on its short side (1920x1080, 1080x1920),
YouTube 4K for anything bigger. A preset sets the codec, bitrate and
resolution class and keeps the canvas's shape, so `--preset youtube1080`
of a 4K project is 1920x1080 and of a 9:16 one 1080x1920.

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

It counts the assets still in the project's media, and any a clip names in
an `asset:<id>` tag (a saved segment's clips carry them for the library
assets they came from), so run it last, after removing media the cut no
longer uses. Sort out everything under "Before
publishing" first. `--optional` adds courtesy credits nobody requires
(Pexels creators).

### Reuse an intro, an outro or a call to action (segments)

A segment is a bit of timeline saved to reuse: a group of clips with their
offsets, settings, effects and keyframes, saved into the shared library's
`Segments/<name>/` with copies of the files they play. Mike saves them from
the timeline (Timeline > Save selection as segment…); agents do the same
from clip IDs or a range:

```bash
tandem timeline --from 0:00 --to 0:08          # find the intro's clips
tandem segments save "Intro" --clips clip_card,clip_title,clip_whoosh --field clip_title=Title
tandem segments save "Outro" --from 10:02 --to 10:15    # every clip wholly inside
tandem segments list
```

`--clips` takes exactly those clips (a linked partner isn't added, so name
the camera's sound too if it should come). `--field clip=Label` makes a
title's words a field: they're asked for on insert, and the words it has now
are the default. A `{{key}}` already in a title is a field too.
Transitions come along when every clip they join is saved: a dissolve
between two of the clips, a fade at one's head or tail. Saving under a name
that's taken fails unless `--replace`. Projects the old version went into
play its files from the library, so the new version keeps every file only
the old one had, and the rest of the old one goes to the Trash.

Then put one on the timeline, as one undo step:

```bash
tandem segments insert "Intro" --at 0 --value title="DECISION MODELS"
tandem segments insert "Like and subscribe" --at 4:12 --mode overwrite
```

Each clip goes on the track with the same name and kind (made if the
project hasn't one), at the same offset, linked to the rest. The segment's
files are added to the project's media where they are in the library (no
copy), and inserting again reuses them; archiving the project copies them
in. `--mode` is `place` (the default: fails where a track is taken),
`overwrite` or `insert` (pushes later clips right). In MCP:
`segments_insert {"name": "Intro", "at": 0, "values": {"title": "..."}}`.

On disk a segment is plain JSON beside its files:

```
Tandem Library/Segments/Intro/
  segment.json      {"version": 1, "name": "Intro", "template": {...}, "media": [...], "savedFrom": "Decision Models", "notes": []}
  card.mov          the files its clips play, named as they were
  whoosh.wav
  warm.cube         and the looks they use
```

`template` is an `insertTemplate` template whose `mediaPath`s and LUT paths
are relative to the folder; `media` holds the media items for those files.

### Archive a finished video

When a video's done it moves to Bruce, Mike's other Mac, which keeps the
archive. A project there has to open with nothing missing, but projects use
files from outside their folder: stickers, sounds, looks and segments from
the shared library, an import's absolute paths, a sound from another
video's folder, a LUT, a font installed only on this Mac. Look first:

```bash
tandem archive --dry-run
```

```
Dry run, nothing changed. Making Decision Models.tandem standalone would bring in 19 files from outside its folder (2.89 GB).
From outside the folder:
  media/music/score.wav  192.2 MB  from ~/dev/convex/convex-videos/decision-models/music/score.wav
  media/main vid/2026-09-24_105434-camera.mov  1.16 GB  from ~/dev/convex/...
  ...
Missing, so left as they are (1):
  /Users/m5-mike/Desktop/old-take.mov  (med_x, 2 clips)
```

Then either make the project's own folder standalone (the files are copied
in and the project points at them, as one undo step credited to you):

```bash
tandem archive
```

or write a standalone copy of the whole folder somewhere else, leaving the
original as it is:

```bash
tandem archive --to "/Volumes/CannMedia/Archive" --dry-run   # the folder by top-level folder, with sizes
tandem archive --to "/Volumes/CannMedia/Archive"
```

The copy is `/Volumes/CannMedia/Archive/<project folder name>/`, with every
path relative, so it opens anywhere. Proxies, mattes, thumbnails and
isolated voice are left out (Tandem makes them again; `--with-cache` keeps
them), as are `node_modules` folders; transcripts and the converted copies
of stickers macOS can't decode always go. Files outside
the folder land in `media/<the folder they were in>/`, shared library files
in `media/Tandem Library/<where they were in it>` (a segment's in
`media/Tandem Library/Segments/<name>/`), a Live Photo's movie beside its
still, LUTs in `assets/lut/` and fonts in `assets/font/` (the shared
library's `Fonts/` is looked in too). Other `.tandem` files in the folder
(versions) get the same treatment.

Every copy is an APFS clone when it can be (instant, no extra space) and is
checked against the original by SHA-256 when it isn't. A different file with
the same name is never replaced; the copy goes beside it as `name 2`.
`archive.json` in the archived folder says where each file came from, with
its checksum and date. Missing files are listed and left as they are.

A run that stops part way (Ctrl-C, a share that went away) changed nothing in
the project; run the same command again and it carries on, using what it
already copied. An archive to the same place later brings that archive up to
date. With the app closed the project stays locked while it copies, so a big
archive to a network share is best run when Mike isn't about to open it; with
the app open, the archive runs in the app.

### Relink missing media

A project opened on another Mac, or a folder tidied by hand, can lose track
of files. `tandem media` marks them `MISSING FILE` and `tandem validate`
fails. The app offers to search a folder when it opens such a project; from
the command line:

```bash
tandem relink --dry-run                        # what it would find in the project folder
tandem relink --search "/Volumes/CannMedia/decision-models"
```

It looks in the project folder and each `--search` folder (subfolders too)
for a file with the same name, and takes it only when its content matches
what the project knew (its fingerprint). A file with no fingerprint is taken
when it's the only one with that name. Then it looks in this Mac's shared
library for whatever's still missing, so a project that used stickers and
sounds from the library on another Mac finds them here; there, only a file
whose content matches is taken. A Live Photo's movie comes back with its
still when it's beside it. It's one undo step.

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
| cards | `tandem cards [--kicker] [--duration] [--insert] [--no-sounds] [--marker]... [--apply]` | `POST /v1/cards {"markers", "kicker", "duration", "insert", "sounds", "apply"}` | `cards` |
| apply | `tandem apply <file or ->` | `POST /v1/apply <batch>` | `apply` |
| undo, redo | `tandem undo`, `tandem redo` | `POST /v1/undo`, `/v1/redo` | `undo`, `redo` |
| history | `tandem history` | `POST /v1/history` | `history` |
| validate | `tandem validate` | `POST /v1/validate` | `validate` |
| frame | `tandem frame <time> -o out.png` | `POST /v1/frame {"time", "output"}` | `frame` (image) |
| screenshot | | `POST /v1/screenshot` | `screenshot` (app only) |
| clip | `tandem clip <start> <end> -o out.mp4` | `POST /v1/clip {"start", "end"}` | `clip` |
| export | `tandem export [--preset] -o out.mp4` | `POST /v1/export {"preset", "output"}` | `export` |
| archive | `tandem archive [<project>] [--to <folder>] [--with-cache] [--dry-run]` | `POST /v1/archive {"to", "withCache", "dryRun"}` | `archive` |
| relink | `tandem relink [--search <folder>]... [--dry-run]` | `POST /v1/relink {"search": [...], "dryRun"}` | `relink` |
| loudness | `tandem loudness` | `POST /v1/loudness` | `loudness` |
| watch | `tandem watch [--once]` | `GET /v1/watch` (events), `POST /v1/watch` (wait) | `watch` |
| effects | `tandem effects` | `POST /v1/effects` | `effects` |

Output paths given to the API are absolute or relative to the project
folder; the CLI makes them absolute from where you run it.

The asset library isn't a project operation, so it has no HTTP endpoint;
the CLI and MCP open the library themselves, and only `use`, `credits` and
the segment `save` and `insert` reach the project (through the app's API
when it's open).

| Asset operation | CLI | MCP tool |
| --- | --- | --- |
| providers | `tandem assets providers` | `assets_providers` |
| search | `tandem assets search "<text>" [--kind] [--provider] [--online]` | `assets_search` |
| fetch | `tandem assets fetch <id>` | |
| use | `tandem assets use <id> [--at] [--duration]` | `assets_use` |
| credits | `tandem assets credits [--optional]` | `assets_credits` |
| generate | `tandem assets generate sfx or music "<prompt>"` | `assets_generate` |
| install-starter | `tandem assets install-starter` | |
| list segments | `tandem segments list` | `segments_list` |
| save a segment | `tandem segments save "<name>" --clips <ids>` or `--from --to` | `segments_save` |
| insert a segment | `tandem segments insert "<name>" --at <time>` | `segments_insert` |

## Troubleshooting

- **"is open in the Tandem app, but the app isn't serving its API"**: the
  app has the project open but no API. Restart or update the app.
- **"busy in another tandem command"**: another command has the project
  open right now. Commands wait up to 15 seconds for it before giving up.
- **"isn't built yet, so this doesn't work in this version of Tandem"**:
  rendering or media analysis isn't in this build.
- **"has no 9:16 frame for the short"**: `--preset short` (or `--format
  portrait`) on a project that isn't 9:16 and has no portrait format yet.
  `tandem short --apply` lays one out; the landscape video exports with
  plain `tandem export`.
- **No pauses or search results**: check `tandem media`; transcripts are
  made in the background after files are added.
- **"... isn't installed, so N text clips are drawn in SF Pro instead"**:
  run the `tandem assets use fontsource:...` it gives. The font goes into
  the project's `assets/font/`, and the app (if it has the project open)
  uses it straight away. For a font Fontsource doesn't have, search with
  `tandem assets search "<name>" --kind font --online`, or pick another
  font for those titles.
- **"This project was saved by a newer Tandem (schema 2)"**: an older
  build opened a project a newer one saved. Update Tandem. Schema 2 is the
  one where a title's own style always wins over its preset.
- **"... is QuickTime Animation, which macOS can't decode"**: stock stickers
  often come as QuickTime Animation or PNG video. Tandem converts them to
  HEVC with ffmpeg (frames and exports wait for it; `tandem media` shows
  `converted`). If the warning says ffmpeg is missing, Mike installs it with
  `brew install ffmpeg`.
- **"Nothing to undo" after editing with the app closed**: headless undo
  history only lasts while nobody else edits the project. `tandem history`
  shows what can be undone.
- **"ElevenLabs refused: ... missing the permission sound_generation"**: the
  key can make music but not sound effects. Mike turns the permission on
  for the key in ElevenLabs; `tandem assets providers` says when it's fixed.
- **"No asset ... in the library"**: search for it first (with `--online`
  for provider assets), then use the ID the search gives.
- **"There's no folder at /Volumes/... to archive into"**: the share isn't
  mounted. Mike connects to it in Finder first.
- **"archive.json ... isn't a Tandem archive manifest"**: a file of that name
  that Tandem didn't write is in the way; it's never written over. Rename it.
- **"The copy of ... didn't match the original"**: a copy failed its
  checksum and was thrown away, and nothing in the project changed. Run it
  again; if it keeps failing, the destination disk is suspect.
- **"There's already a segment called ..."**: pick another name, or pass
  `--replace` (`replace: true`) to save over it; files only the old one had
  stay, and the rest of it goes to the Trash.
- **"Several segments are called ..."**: two segment folders give the same
  name; use the folder's name (`tandem segments list --json` has each
  `id`).
- **"... is missing ... from .../Segments/..., so it wasn't inserted"**: a
  file was deleted from the segment's folder. Put it back, or save the
  segment again from a project that has it.
- **"There's no shared library at ... yet"**: the app makes
  `~/Movies/Tandem Library` the first time it opens after installing, and
  `tandem segments save` makes it too.
