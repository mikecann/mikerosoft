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

- [x] Scan the project folder, probe files, guess roles, pair record-it takes [media]
- [x] Watch the folder and add new files as they land [media]
- [x] Analysis cache and one job scheduler with priorities and an encoder lock [media]
- [x] Thumbnails and waveforms [media]
- [x] Loudness (EBU R128 integrated, true peak, LRA) in Swift [media]
- [x] 1080p HEVC proxies (all-intra, then a keyframe every 15 frames so still areas stop crawling) [media]
- [x] Proxies of overlays and stickers with alpha keep it (HEVC with alpha), so the viewer shows the track below through them [media]
- [x] Transcripts with SpeechAnalyzer, word timings in media time [media]
- [x] Person matte for the cutout (Vision), greyscale HEVC [media]
- [x] Matte v2: accurate person mask plus the foreground subject mask (keeps the mic), smoothed only where the picture is still; about 9x less flicker, 41 fps [media]
- [x] Analysis follows the edit: heavy jobs only for what the timeline uses [integration]
- [x] Isolated voice (AUSoundIsolation), latency compensated [media]
- [x] Video macOS can't decode (QuickTime Animation and PNG stock stickers) converted to HEVC with alpha through ffmpeg, in projects and the asset library; renders no longer fail with "Cannot Decode" [media]

## Milestone 3: render and export

- [x] Transform maths shared by viewer and export, with tests [render]
- [x] Composition builder: video layers, audio tracks, proxies for playback [render]
- [x] Compositor: transform, crop, opacity, solids, adjustment layers, cutout with matte [render]
- [x] Effects: colour, HSL, vignette, sharpen, LUT, blur, pixelate, drop shadow, border, rounded corners, Core Image bindings [render]
- [x] Transitions: dissolve, fade to and from black, push (4 directions), slide, cut slide, wipe, zoom [render]
- [x] Native titles: Core Text, the four styles, in and out animations, word-by-word captions [render]
- [x] Audio mix: gain, fades, keyframes, normalisation, voice isolation, crossfades, 3 ms micro-fades, pitch-kept speed changes [render]
- [x] pitchShift audio effect [render]
- [ ] Graphic template clips (Remotion props rendered in the background) [render]
- [x] Frame renderer for grabs and tests [render]
- [x] Exporter: VideoToolbox speed priority, presets, master loudness to -14 LUFS under -1 dBTP, range export, snapshot beside the file [render] (the whole 11 min v14 edit in 156 s, 4.3x real time)

## Milestone 4: agents

- [x] Service: status, media, transcript, search, timeline, apply (with dry run), undo, redo, history, frame, clip, export, loudness, validate, watch, effects, screenshot [api]
- [x] Readable timeline dump for agents (text, --summary, --words, JSON) [api]
- [x] Local HTTP server with token, event stream for watch [api]
- [x] `tandem` CLI, headless when the app is closed (undo kept on disk), talks to the app when open [api]
- [x] `tandem mcp` stdio server (both MCP protocol eras) [api]
- [x] Transcript tools: find phrase, list pauses, tighten pauses [api]
- [x] docs/AGENTS.md with an example of every command, checked by tests [api]

## Milestone 5: the app

- [x] Shell in the Graphite look: window, menus, open, new, recent, save as version [app]
- [x] Media browser from the folder: takes, graphics, B-roll, music, SFX, search [app]
- [x] Viewer with transport, J K L, proxy toggle, fit [app]
- [x] Timeline: tracks, clips with thumbnails and waveforms, ruler, playhead, markers, transcript lane, zoom [app]
- [x] Tools: select, blade, trim, ripple trim, roll, slip, slide, snapping, drag to move, overwrite and insert, link, ripple delete, I and O with lift and extract, nudge, markers [app]
- [x] Keymap (Premiere-style defaults, JSON), 1 to 4 for layout presets [app]
- [x] Inspector built from parameter definitions: Video, Colour, Audio, Info [app]
- [x] Export sheet and job status bar [app]
- [x] Activity feed: agent edits with labels, undo per batch [app]
- [x] Hosts the API while a project is open [app]
- [x] Keyframe editing in the timeline, drops from Finder, save failures shown and retried [app]
- [x] Exact paused frames from original files, including remuxed open-GOP files without a keyframe table [render]
- [x] Cursors that say what a press does: diagonal arrows on the viewer's corner handles, a hand on the selected layer and on markers, trim and roll arrows on clip edges, a blade, row resize on lane edges, zoom with Z held (`CursorKind`) [app]

## Milestone 6: real projects

- [x] Import the decision-models EDL into a .tandem project [importer] (676.6 s vs v14 667.3 s: Mike's hand trims after the pipeline)
- [x] Import Filmora .wfp projects [importer] (v14 487/487 clips and 34/34 transitions exact; 119-project corpus imports without failures)
- [x] Render the imported v14 and compare frames against Filmora's export [render] (placement exact; grade within about 4/255)
- [x] `tandem import filmora|edl|compare` in the CLI [integration]

## Wave 2

- [x] Asset library: catalogue (SQLite FTS5), providers (import folders, ElevenLabs, Noto, Iconify, SVGL, Fontsource, Pexels, Pixabay, Freesound), normalising (alpha stickers to HEVC, Lottie, SVG, audio loudness), project use and credits [assets]
- [x] Asset commands in the CLI and MCP (`tandem assets ...`, five MCP tools) [api]
- [x] Asset browser in the app: search, sources, favourites, hover previews, drag or double-click to place, credits [app]
- [x] ElevenLabs Generate, the big Space preview, looks and fonts dropped onto clips [app]
- [x] Sources as providers; paid libraries through watched import folders. ElevenLabs sound effects need the key's `sound_generation` permission (music works)
- [~] Title and template pack (core insertTemplate done): plain label, pop callout, two-line section header, version number, section card, Like and Subscribe, Comment Below
- [x] Shared library: one watched folder on this Mac (`~/Movies/Tandem Library`, moved in Settings) for stickers, graphics, sounds, music, looks, fonts and segments; its files are used where they are, archiving copies them in, relink looks there [assets, api, app]
- [x] Saved segments: Save selection as segment (menu bar and clip menu), the Text tab's Segments, `tandem segments list/save/insert` and `segments_*` MCP tools; a segment carries copies of its files [core, api, app]
- [ ] Segments keep the transitions between their clips; the app asks for a segment's words when it goes in
- [ ] Stickers: Lottie and HEVC with alpha
- [x] Word-by-word captions from the transcripts (`tandem captions`, MCP `captions`) [integration]
- [x] Colour tab like other editors': whole take or this clip, then Light, Colour, colour wheels (the new `colorWheels` effect), a Lightroom-style colour mixer, vignette, sharpen and LUT; sliders with gradient tracks, reset, scrubbing and typing [app, render]
- [x] Portrait short from the same edit: `setFormatLayout`, `tandem short`, portrait frames and the short export preset [integration]
- [ ] Segment render cache for fast re-exports
- [ ] Remotion graphics clips with props, rendered in the background
- [ ] Own playback engine (VTDecompressionSession, frame cache, audio clock) if AVPlayer scrubbing isn't fast enough

## Not building

Curves, HDR, chroma key, blend modes, stabilisation, tracking, video
denoise, reverse, EQ, auto reframe, auto ducking, in-app music generation.
Mike used none of these in 51 projects, or used them once. (Colour wheels
were on this list too; they're in the Colour tab because they're what any
other editor's grade starts from.)
