# Tandem V1 plan

What V1 has to do: open a video folder, show the takes and media in it, let
Mike cut a 6 to 15 minute Convex video the way he did in Filmora (camera take,
screen with a cutout PiP, B-roll, titles, music, SFX), and export a
loudness-matched 4K file. Agents can do everything he can through the CLI and
MCP. This list merges Mike's brief, the Filmora audit (51 projects), the
spikes, Astra's review and Fable's review.

Status: `[x]` done, `[~]` in progress, `[ ]` not started. Owner in brackets.

## Milestone 1: the engine

- [x] Model, time (flicks), JSON with lenient decoding [core]
- [x] Edit commands and batches, one coordinator, undo, revisions, idempotency [core]
- [x] Ripple modes (cut, follow, off), linked clips, markers moving with ripples [core]
- [x] Blade, trim, ripple trim, roll, slip, slide, speed, move, lift, extract, insert, close gap, insert time [core]
- [x] Transitions with handle checks, effects, keyframes, markers [core]
- [x] Validator and random-edit invariant tests [core]
- [x] Journal with seeded IDs, atomic saves, backups, crash recovery [core]
- [x] Project session: lock, autosave, recovery [api]
- [x] Layout presets (full, PiP right, PiP left, split) and zoom-to-region as commands [core]
- [x] JSON schema for commands, checked against every EditCommand case [api]

## Milestone 2: media

- [ ] Scan the project folder, probe files, guess roles, pair record-it takes [media]
- [ ] Watch the folder and add new files as they land [media]
- [ ] Analysis cache and one job scheduler with priorities and an encoder lock [media]
- [ ] Thumbnails and waveforms [media]
- [ ] Loudness (EBU R128 integrated, true peak, LRA) in Swift [media]
- [ ] 1080p all-intra HEVC proxies [media]
- [ ] Transcripts with SpeechAnalyzer, word timings in media time [media]
- [ ] Person matte for the cutout (Vision), greyscale HEVC [media]
- [ ] Isolated voice (AUSoundIsolation), latency compensated [media]

## Milestone 3: render and export

- [ ] Transform maths shared by viewer and export, with tests [render]
- [ ] Composition builder: video layers, audio tracks, proxies for playback [render]
- [ ] Compositor: transform, crop, opacity, solids, adjustment layers, cutout with matte [render]
- [ ] Effects: colour, HSL, vignette, sharpen, LUT, blur, pixelate, drop shadow, border, rounded corners, Core Image bindings [render]
- [ ] Transitions: dissolve, fade to and from black, push (4 directions), slide, cut slide, wipe, zoom [render]
- [ ] Native titles: Core Text, the four styles, in and out animations, word-by-word captions [render]
- [ ] Audio mix: gain, fades, keyframes, normalisation, voice isolation, crossfades, 3 ms micro-fades [render]
- [ ] Frame renderer for grabs and tests [render]
- [ ] Exporter: VideoToolbox speed priority, presets, master loudness to -14 LUFS under -1 dBTP, range export, snapshot beside the file [render]

## Milestone 4: agents

- [x] Service: status, media, transcript, search, timeline, apply (with dry run), undo, redo, history, frame, clip, export, loudness, validate, watch, effects, screenshot [api]
- [x] Readable timeline dump for agents (text, --summary, --words, JSON) [api]
- [x] Local HTTP server with token, event stream for watch [api]
- [x] `tandem` CLI, headless when the app is closed (undo kept on disk), talks to the app when open [api]
- [x] `tandem mcp` stdio server (both MCP protocol eras) [api]
- [x] Transcript tools: find phrase, list pauses, tighten pauses [api]
- [x] docs/AGENTS.md with an example of every command, checked by tests [api]

## Milestone 5: the app

- [ ] Shell in the Graphite look: window, menus, open, new, recent, save as version [app]
- [ ] Media browser from the folder: takes, graphics, B-roll, music, SFX, search [app]
- [ ] Viewer with transport, J K L, proxy toggle, fit [app]
- [ ] Timeline: tracks, clips with thumbnails and waveforms, ruler, playhead, markers, transcript lane, zoom [app]
- [ ] Tools: select, blade, trim, ripple trim, roll, slip, slide, snapping, drag to move, overwrite and insert, link, ripple delete, I and O with lift and extract, nudge, markers [app]
- [ ] Keymap (Premiere-style defaults, JSON), 1 to 4 for layout presets [app]
- [ ] Inspector built from parameter definitions: Video, Colour, Audio, Info [app]
- [ ] Export sheet and job status bar [app]
- [ ] Activity feed: agent edits with labels, undo per batch [app]
- [ ] Hosts the API while a project is open [app]

## Milestone 6: real projects

- [x] Import the decision-models EDL into a .tandem project [importer] (676.6 s vs v14 667.3 s: Mike's hand trims after the pipeline)
- [x] Import Filmora .wfp projects [importer] (v14 487/487 clips and 34/34 transitions exact; 119-project corpus imports without failures)
- [ ] Render the imported v14 and compare frames against Filmora's export [render]
- [x] `tandem import filmora|edl|compare` in the CLI [integration]

## Wave 2

- [~] Asset library: catalogue (SQLite FTS5), providers, normalising, credits [assets]; browser UI after the app lands
- [ ] Sources: Freesound (CC0), Pexels and Pixabay, ElevenLabs sound effects, LottieFiles, Google Fonts; paid libraries through a watched folder
- [~] Title and template pack (core insertTemplate done): plain label, pop callout, two-line section header, version number, section card, Like and Subscribe, Comment Below
- [ ] Stickers: Lottie and HEVC with alpha
- [ ] Portrait short layout (screen top, camera bottom, captions between)
- [ ] Segment render cache for fast re-exports
- [ ] Remotion graphics clips with props, rendered in the background
- [ ] Own playback engine (VTDecompressionSession, frame cache, audio clock) if AVPlayer scrubbing isn't fast enough

## Not building

Colour wheels, curves, HDR, chroma key, blend modes, stabilisation, tracking,
video denoise, reverse, EQ, auto reframe, auto ducking, in-app music
generation. Mike used none of these in 51 projects, or used them once.
