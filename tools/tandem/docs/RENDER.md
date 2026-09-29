# Tandem render module

How a project becomes pixels and sound: the viewer, frame grabs and export
all go through the same path, so what Mike sees is what YouTube gets.

```
Project ──RenderPlanner──▶ RenderPlan (pure)
                             │
                 CompositionAssembler (AVFoundation)
                             │
        AVMutableComposition + AVVideoComposition + AVAudioMix
           │                  │ TandemCompositor (Core Image, Metal)
           │                  │   └─ FrameComposer: one frame from a layer stack
     AVPlayer (viewer)   FrameRenderer (AVAssetImageGenerator, RGBA)
                         Exporter (AVAssetReader ▶ VideoToolbox ▶ AVAssetWriter)
```

## Files

| File | What it does |
| --- | --- |
| `RenderAPI.swift` | The public contract: `RenderContext`, `CompositionBuilder`, `FrameRenderer`, `ExportPreset`, `Exporter` |
| `LayerMath.swift` | Placement maths shared with the viewer: fit, transform, orientation, crop, zoom to rectangle, format overrides |
| `RenderPlan.swift` | Pure plan: composition track pools (A/B), instruction splits and layer stacks, audio segments |
| `AudioEnvelope.swift` | Clip gain, fades, keyframes, crossfades and micro-fades as volume breakpoints |
| `CompositionAssembler.swift` | Plan to AVFoundation: source loading, speed, freeze, hold, base track, audio mix |
| `Compositor.swift` | `TandemInstruction`, `TandemCompositor` (4:2:0 video range) and `TandemRGBCompositor` (grabs) |
| `FrameComposer.swift` | The per-layer pipeline, cutout, repair masks, text layers, still image cache |
| `Effects.swift` | Colour, HSL, vignette, sharpen, LUT and Core Image bindings; rounded corners, border, drop shadow |
| `Kernels.swift` | Runtime-compiled Metal Core Image kernels |
| `Transitions.swift` | All transition types |
| `TextRenderer.swift`, `TitlePresets.swift` | Core Text titles, presets, animations, word captions |
| `Limiter.swift` | Lookahead true-peak limiter |
| `Export.swift` | Loudness passes, VideoToolbox encoder, mastered audio, snapshot |
| `RenderAssets.swift` | `RenderAssets`: proxies, mattes, isolated voice, loudness, converted copies (from `MediaAnalysis`) |
| `ConvertedMedia.swift` | Frame grabs and exports convert what macOS can't decode before they build |

## Timeline rules

- Video tracks draw bottom to top. Hidden tracks, disabled clips and clips
  hidden in the current format are skipped.
- Every media video segment goes on the first free composition track of one
  shared pool, so clips overlapping in a centred transition land on
  different tracks (A/B). Cutout mattes get their own segments with the same
  time mapping. A tiny black movie underlies everything, so the video spans
  the whole timeline even with only titles or a trailing gap.
- A two-sided transition is centred on the cut (the outgoing clip plays on
  for half, the incoming one starts half early from its handle). A one-sided
  transition sits inside its clip. Short clips with overlapping transitions
  nest: `(A to B) to C`.
- Speed uses `scaleTimeRange`; a freeze frame is one frame stretched; media
  that runs out holds its last frame (video) or goes quiet (audio).
- Instructions split at every visible clip edge and transition edge.
- Graphic clips (`.graphic`) aren't rendered yet: there's no rendered-file
  contract. They produce a warning.
- A file macOS can't decode (`MediaItem.undecodableCodec`: QuickTime
  Animation or PNG stickers) plays from its `converted` HEVC copy
  (docs/MEDIA.md). Frame grabs and exports make a missing copy before they
  build (`ConvertedMedia`), about a quarter of a second for a sticker, so
  the sticker is in the picture. The viewer doesn't wait: the clip is left
  out, with a warning, until the background conversion lands. A file that
  can't be converted (no ffmpeg) is left out with a warning saying why,
  and a source that turns out undecodable anyway (scanned before Tandem
  checked) is loaded without its video. One undecodable track used to fail
  the whole composition with "Cannot Decode".

## Layer pipeline

Per layer: source frame the right way up (the track's preferred transform),
the media's `look`, the clip's colour and utility effects in order, crop,
cutout, rounded corners, border, transform, drop shadow, opacity.
Keyframes are evaluated per frame at clip-relative time. Adjustment layers
apply their effects to everything below, mixed in by their opacity.

- **Units.** `px@1080` values are output pixels at 1080p, scaled by the
  canvas's short side (a 4K export doubles them, a 9:16 short keeps them).
  Effects that run in source pixels divide by the layer's scale, so a blur
  or border looks the same whatever the zoom. Cutout feather and choke use
  the same rule.
- **Colour.** Core Image colour management is off: pixels are composited as
  the encoded values they are, like Filmora. Sources are decoded with their
  own YCbCr matrix and range (the Kiyo camera is full-range BT.601);
  output is tagged BT.709 video range. Solid and text colours are sRGB
  code values. The video composition carries no colour properties: with
  them AVFoundation re-tags every source frame BT.709 without converting
  it, and BT.601 footage came out with the wrong matrix (red 180/40/50 as
  192/54/48). The compositor also attaches Core Media's 709 colour space
  to its output, as decoders do for 709 files: with the tags alone,
  AVPlayerLayer uses the exact BT.709 curve and lifts the shadows (black
  16 showed as 32 on screen, against 14 for paused stills and exports).
- **Colour effect.** One kernel: exposure (stops), contrast (pivot mid grey,
  +100 is 1.5x), black level, highlights, shadows, saturation, vibrance,
  temperature, tint. Black level and the vignette were calibrated against
  Filmora's v14 export of the same footage (tone percentiles and the radial
  fall-off match to about 1%). Contrast hasn't been calibrated yet: v14 has
  none.
- **HSL.** Eight ranges (red 0, orange 30, yellow 60, green 120, aqua 180,
  blue 240, purple 270, magenta 300 degrees); a pixel blends its two
  neighbours; near-greys are untouched. Hue ±100 is ±30 degrees.
- **LUT.** `.cube` 3D or 1D (1D is expanded to 33 points), path relative to
  the project folder, parsed once and cached.
- **Cutout.** The matte multiplies alpha (its luma, full range). Feather,
  choke and repair shapes are worked out at the matte's resolution. The
  matte covers the whole frame with the source's frame times, and its own
  preferred transform is applied. A clip uses the matte made in its cutout
  mode (`matteURL(for:mode:)`), else the default one; no matte yet means no
  cutout, with a warning.
- **Border** follows the alpha when the layer is cut out, otherwise it's a
  crisp frame outside the (rounded) rectangle.
- **Drop shadow** follows the alpha. `angle` is where the light comes from,
  degrees anticlockwise from the right, so the default 135 casts down right.
- **Text** is drawn with Core Text at output resolution (times the clip's own
  scale, up to 4x, so big titles stay sharp) and cached per content, size
  and animation state. Fonts that aren't installed fall back to the system
  font at the requested weight (CSS weights, 100 to 900). Lines wrap at 90%
  of the canvas width.

## Transitions

Directions are the direction of motion; the default is `left`.

| Type | Behaviour |
| --- | --- |
| dissolve | Even mix; one-sided fades from or to transparent |
| fadeToBlack, fadeFromBlack | A dip: the outgoing side darkens, the incoming side brightens; one-sided uses its whole length. Alpha is kept, so a PiP dips to a dark silhouette |
| push | Both shots move together, ease in and out |
| slide | The incoming shot slides over a still outgoing one |
| cutSlide | A short, fast push (quartic ease) with a hint of motion blur |
| wipe | A soft edge sweeps in the direction of motion |
| zoom | Cross zoom: into the outgoing shot, out of the incoming one, with a light zoom blur |

On audio tracks every transition is an equal-power crossfade.

## Titles

`TextContent.preset` picks a row from `TitlePresets.builtIn`: `label`,
`callout`, `sectionHeader` (two lines, the first smaller in the accent
colour), `version`, and `caption` (word by word, the spoken word
highlighted). The clip's `style` overrides any field it changes from
`TextStyle()`'s defaults; `animationIn`/`animationOut` override when set;
`animationDuration` overrides when it isn't the 0.4 s default. A text clip
without video properties sits at the preset's position. Animation names:
`fade`, `pop` (scale with overshoot), `slideUp`, `typewriter`, plus common
aliases (`popIn`, `fadeOut`...).

## Audio

- Clip gain (dB, -96 or lower is silence), `normalizeTo` (target minus the
  file's measured loudness, capped at ±30 dB, nothing for a silent file),
  `audio.gainDB` keyframes, fades (equal power), transitions, and voice
  isolation (original times 1 - v plus the isolated file times v) all
  multiply into one envelope per segment, sampled finely enough that
  AVAudioMix's linear ramps sound smooth. AVAudioMix volumes above 1 work,
  so boosts are real. Levels below has how normalise and gain combine.
- Every hard cut gets a 3 ms fade each side. Joins that continue the same
  media seamlessly (same file, contiguous source, same speed and gain) don't.
- Speed changes keep their pitch (spectral time-pitch).
- `pitchShift` (semitones, keyframable) renders the clip's sound once
  through Apple's time-pitch unit, offline, into a cached copy in
  `~/Library/Caches/Tandem/pitch` (keyed by the file, range, pitch and,
  for keyframes, the timing), and the composition plays the copy. The unit
  adds no delay offline, so sync is untouched; a speed change on the same
  clip still keeps the shifted pitch.

## Levels

Speech is levelled per take, then export masters the whole mix.

- A clip with `normalizeTo` gets a constant gain: the target minus its
  file's integrated loudness (BS.1770, measured in the background), at most
  30 dB either way, and none for a silent file. The clip gain (`gainDB`, or
  its keyframes) is added on top, then fades. A -32.2 LUFS take normalised
  to -20 with +2 dB plays at about -18. The maths is in `AudioLevels`; the
  render plan, `tandem loudness` and the Audio tab share it, and the viewer,
  review clips and export all take their sound from the same plan
  (`LevelRenderTests` checks the viewer's mix against the export's). Stills
  have no sound.
- Speech is a camera's sound, a file with no clearer role (a rendered
  intro), or anything on a `cut` audio track like Voice, muted or not.
  Placing it normalises it to `settings.speechLoudness` with no gain, and
  `normalizeSpeech` (Normalise speech clips in the Audio tab) sets every
  speech clip to it and clears its gain, as one undo step. Changing the
  setting moves the clips normalised to the old level. Music (-31 dB with a
  2 s fade out) and sound effects (-15 dB) keep plain gains.
- Export then brings the mix to -14 LUFS under -1 dBTP, so the speech level
  decides the balance against music and sound effects, and how loud the
  viewer plays (it plays the mix before the master), not how loud the video
  is.

The speech level is -20 LUFS because:

- It's where Mike's voice played in Filmora. Filmora's Auto Normalization,
  on for the voice in every Filmora project in convex-videos (24 files
  from five videos), levels a file to about -24 LUFS on Tandem's meter
  (Filmora says -23), and his LoudnessGain of +1.9 to +4.1 dB goes on top.
  On the v14 export, 62 voice clips from three takes played at -24.1 LUFS
  plus their LoudnessGain (spread 0.7 dB) and the music at its plain
  VolumeGain; the voice sits at -20.4 LUFS and the whole export at -20.1.
  The -31 and -15 dB music and SFX gains come from those projects, so they
  keep the balance Mike mixed by ear.
- It's the quiet end of the -16 to -20 LUFS that AES recommends for speech
  streams (TD1004, TD1008), and leaves the master about 6 dB to add.
- The viewer has no limiter. Levelled to -20, the demo's 635 s of voice
  goes over 0 dBFS in 4 clips by at most 2 dB; at -18 in 22 clips by up to
  4 dB, at -16 in 58 by up to 6 dB, which would crackle in the app and not
  in the export.

On the v14 demo, Normalise speech clips moves its 230 speech clips (Voice,
Voice 2 and the intro) to -20 LUFS. The export still measures -14.0 LUFS
with true peaks at -1.1 dBTP before the AAC encode (ffmpeg reads -0.8 from
the file, and -0.9 before the change: the codec's overshoot). The voice
now sits 23.7 dB over the music in the pauses, against 25.9 dB in
Filmora's own export and 18.0 dB with the gains the Filmora import copied.

A Filmora import normalises speech to the speech level, the way placing
does. It used to copy LoudnessGain as a plain gain, which put the voice
8 dB lower against the music than Filmora played it. `--keep-levels`
keeps Filmora's own levels instead, as `normalizeTo: -24` plus the clip's
gain. The decision-models EDL recipe's -28.74 LUFS voice came from the same
reading of LoudnessGain; it now uses the speech level.

## Export

1. Build the composition at the preset's size and format (never proxies).
2. Measure the mix (audio only, fast). If the gain would push true peaks
   over the ceiling, the limiter will take some loudness with them, so one
   more pass runs four gain and limiter chains side by side (the gain plus
   0, 0.75, 1.5 and 2.5 dB) and interpolates the gain that hits the
   target. On the v14 edit that lands within 0.02 LU.
3. Composed frames go to a hardware `VTCompressionSession` (HEVC Main or
   H.264 High, speed priority, preset average bitrate, 2 s GOP, BT.709) and
   are muxed with AVAssetWriter. The mix gets the master gain and the
   true-peak limiter (5 ms lookahead, 4x oversampled detection, 0.1 dB
   margin, delay compensated), then AAC 48 kHz stereo. Timelines without
   sound get a silent track.
4. `<output>.tandem` is written beside the file: the project with absolute
   media paths and `export.*` metadata.

The preset's `loudnessTarget` and `truePeakCeiling` are used as given (nil
leaves the mix alone). To follow a project's own settings, build the preset
from `project.settings`. The encoder lock is held at `.export` priority
while encoding, released on every exit including cancel and errors (not
held during the loudness passes, which don't encode). Outputs must be
.mp4, .mov or .m4v and can't be one of the project's media files.

## Proxies

The viewer plays 1080p proxies (docs/MEDIA.md has how they're made);
paused stills, API frame grabs and export read the originals. Since proxy
version 3 a proxy has a keyframe every 15 frames with P-frames between, no
reordering, at quality 0.78.

Versions 1 and 2 were all keyframes, so every frame's compression noise was
new and crawled over still walls and screen text while playing, gone the
moment the player paused. A P-frame leaves a still area as it was. The costs
are a tick at each keyframe, where the noise changes all at once, and seeks
that decode from the keyframe before.

Measured on the demo footage (`ProxyRealMediaTests` pins these): a minute of
Mike's camera and of his screen recording through `ProxyJob`, and 150 frames
of still areas in it: the wall beside him, and the sidebar and code boxes of
the screen while only the pointer moves. Changes are the mean absolute
change of 8x8 block means (luma levels) from one frame to the next, into
keyframes and into the rest; the deviation is that of the block means over
the 5 s, the measure behind the choice of 0.6.

| Proxies | Wall: a frame | Wall: at keyframes | Wall: deviation | Sidebar: a frame / keyframes | Text: a frame / keyframes | Camera MB/min | Screen MB/min |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Original | 0.13 | 0.26, every 2 s | 0.33 | 0.013 / 0.075 | 0.004 / 0.040 | 104 | 5 (whole file) |
| All keyframes, 0.6 (version 2) | 0.45 | every frame is one | 0.50 | 0.113 | 0.044 | 105 | 92 |
| Every 15, 0.6 | 0.044 | 0.54 | 0.47 | 0.023 / 0.19 | 0.014 / 0.089 | 16 | 7 |
| Every 15, 0.75 | 0.056 | 0.35 | 0.36 | 0.007 / 0.085 | 0.002 / 0.030 | 67 | 11 |
| Every 15, 0.78 (version 3) | 0.067 | 0.31 | 0.35 | 0.007 / 0.070 | 0.003 / 0.030 | 95 | 13 |
| Every 15, 0.8 | 0.071 | 0.29 | 0.34 | 0.007 / 0.070 | 0.003 / 0.028 | 111 | 14 |
| Every 30, 0.8 | 0.065 | 0.32 | 0.34 | 0.004 / 0.081 | 0.001 / 0.024 | 103 | 9 |

- The crawl is gone: a still wall changes 0.067 a frame where it changed
  0.45, half as much as in the camera file itself, whose sensor noise the
  proxy mostly drops. Screen text changes less than in the original.
- The tick is about the camera's own. Its keyframes (every 2 s) change the
  wall by 0.26; the proxy's (twice a second) by 0.31. Over 32x32 blocks,
  where a change of brightness would show as pumping, the proxy's tick is
  0.12, against 0.14 at the camera's keyframes and 0.09 for its ordinary
  change from frame to frame. Fine detail doesn't breathe either: it drops
  9% into a proxy keyframe, where the camera's keyframes add 27%. On the
  screen the ticks are no bigger than the recording's own keyframes'. At
  quality 0.6 the tick was bigger than all-intra's change every frame,
  which is why the quality went up.
- Quality rounds in steps: 0.76 and 0.77 make the same file, as do 0.79 and
  0.8; 0.78 is the highest step no bigger than all-intra at 0.6. Over the
  whole demo (24 minutes each of camera and screen, and some b-roll) version
  3 proxies take 2.6 GB where version 2 took 4.0: 97 MB a minute of camera
  (was 105), 11 of screen (was 57). They build as fast: 3.7 s a minute of 4K
  camera, 2.3 of screen recording.
- A keyframe every 30 frames saves little (the camera at 0.8 is 105 MB a
  minute) and costs seeks: see below.

The viewer's random access, on the whole v14 edit (screen, camera PiP with
its cutout matte, b-roll) built from each set of proxies as the viewer builds
it: an exact `AVPlayer` seek of a paused player, timed until the frame
reaches the player's output, at 150 random frames, twice. Steps are the arrow
keys: a dozen frames forwards and two dozen back from 8 places. Drags ask
for a new time 60 times a second, as dragging the ruler does, and count the
frames that reach the output.

| Proxies | Seek p50 / p95 | A frame back p50 / p95 | A frame forward p95 | Dragging backwards, 1x / 4x |
| --- | --- | --- | --- | --- |
| All keyframes, 0.6 | 7.1 / 9.2 ms | 4.5 / 7.9 ms | 5.5 ms | 60 / 60 frames a second |
| Every 15, 0.78 | 11.5 / 15.8 ms | 9.3 / 14.2 ms | 5.8 ms | 60 / 60 |
| Every 30, 0.8 | 15.9 / 24.8 ms | 14.3 / 22.6 ms | 5.4 ms | 47 / 34 |
| The 4K originals | 45 / 146 ms | 31 / 190 ms | 11 ms | 30 / 3.5 |

(The last two rows are from an earlier run, in which all-intra was 6.2 /
8.3 ms.) A frame forward carries on decoding, so it costs the same; a frame
back decodes from the keyframe. Forward drags show every frame either way.
Playing at 1x and 8x and backwards (J: the composition can play in reverse)
shows as many frames a second with either proxy. A frame grab through proxies
(project icons) takes 35 ms at p50 against 33. `ProxyExactFrameTests` checks
that seeks, steps across keyframes both ways, and playing forwards and
backwards from a paused frame show the frame for their time. The whole-demo
comparison is `~/dev/me/tandem-research/proxy-gop/ProxyGOPExperiment.swift`,
kept out of the package, and `compare/` beside it has a side-by-side clip of
the wall (the original, all keyframes at 0.6, every 15 at 0.78).

## Random access

The frame at a time is always the last one at or before it: variable frame
rate recordings hold their frame through static gaps (up to 20 s in Mike's
screen recordings). AVFoundation gets that right on its own.

What it gets wrong is open-GOP HEVC that doesn't mark its keyframes. A CRA
keyframe's leading frames show just before it but decode after it,
referring back to the previous GOP, and a file says which keyframes are
CRAs with a `sync` sample group. record-it's files have one; copies
remuxed by ffmpeg (`-c copy`) lose it, like decision-models'
`edit/main-screen.mov` and `edit/main-camera.mov`. Seeking into those
leading frames (about 4% of that screen file) then:

- returns nothing to the compositor (black frame grabs, a black paused
  player: the bug the app hit at 404 s of v14),
- or repeats the previous clip's frame when a cut starts on them,
- or stalls an AVAssetReader for good when its first frame is one of them
  (a range export starting there never finished).

Decoding straight through from a little earlier gets them right, which is
why full exports were fine. So:

- `LeadingFrameMap` reads a file's sample tables (in 20 ms for a 24 minute
  recording) and lists the leading-frame windows, for HEVC with frame
  reordering, sync samples and no `sync` group. Other files get no map.
- A segment that starts inside a window goes into the composition from the
  window's keyframe; the frames before it are left out.
- `FrameRecovery` decodes a frame directly, reading from a second before
  (backing off to 4, 16 and 64 s if the start lands on undecodable frames
  too) and keeping the reader open so the next frames continue from it. The
  compositor uses it for frames left out, for any window frame in a grab,
  and whenever AVFoundation hands it no frame for a layer that should show.
- A range export starting inside a window reads from a moment before it and
  drops what comes before the range (the frame showing at the start goes in
  at the start).
- If AVFoundation stalls anyway, the export gives up after two minutes with
  no frames ("reading the timeline stalled") rather than hanging, and
  cancel wakes it.

Filmora shows the nearest frame of variable frame rate footage, Tandem the
last one at or before the time, so mid-scroll the two can be a frame apart.

## Measured (M5 Pro, release build)

| Job | Speed |
| --- | --- |
| 60 s 4K: screen + 50% cutout PiP camera with grade and shadow, voice, music, HEVC 80 Mbps | 15.8 s, 3.8x real time |
| Same at 30 Mbps | 3.7x |
| 60 s range of the imported v14 edit (494 clips) | 4.4x |
| The whole v14 edit, 11 min 7 s, HEVC 80 Mbps | 156 s, 4.3x, -14.09 LUFS, -1.1 dBTP (loudness passes about 5% of it) |
| Frame grab, 4K composite (first grab builds the composition) | 0.05 to 0.4 s |
| Frame grab that decodes leading frames directly | 0.1 to 0.25 s |
| 20 s of a 4K still with a title and shadow | 4.0x |

The spike's plain composite managed about 3.5x; the encoder is the limit.

## Gotchas

- Core Image (macOS 26) runs the first-used kernel's code for every
  stitchable kernel compiled in the same `kernels(withMetalString:)` call,
  and `destination` coordinates come back as zero when a kernel has other
  arguments. Each kernel is compiled on its own and the vignette uses a
  generated mask. There's a regression test.
- `CGColor(red:green:blue:alpha:)` is Generic RGB: drawing it into an sRGB
  context colour-matches it. Use `CGColor(srgbRed:...)`.
- Setting `colorPrimaries`, `colorTransferFunction` or `colorYCbCrMatrix` on
  a video composition with a custom compositor re-tags the source frames
  without converting them. And a pixel buffer tagged BT.709 with no
  `CGColorSpace` attachment shows lighter in AVPlayerLayer than the same
  pixels as a CGImage. `PlaybackMatchTests` covers both.
- A `FrameRenderer` keeps the composition it first built. The viewer makes
  a new one after every rebuild, since mattes and proxies arrive later
  than edits.
- AVAssetWriter interleaves inputs: pushing all video before any audio
  stalls. Pull each input with `requestMediaDataWhenReady`.
- Calling `cancelReading()` on an AVAssetReader while another thread is in
  `copyNextSampleBuffer()`, or reading an output after its reader has been
  released, crashes. Export cancel is a flag: the encoder feed and muxers
  stop at the next sample, the feed thread (which holds the reader) is
  joined, and only then is the reader cancelled.

## Tests

`swift test --package-path tools/tandem` runs the render tests in about
8 s (the whole package in about 40 s):
pure maths and plan tests, golden-pixel compositor tests with stand-in
frames, end-to-end grabs and exports of synthetic movies (frame-number
stripes, a flash and a beep, tones with clicks). Real footage is opt-in:

```
TANDEM_REAL_MEDIA=1 swift test -c release -Xswiftc -enable-testing \
    --package-path tools/tandem --filter RealMediaTests
```

It reads the decision-models folder and the imported v14 project (never
writing there) and writes to `/private/tmp/claude-501/tandem-render/bench`.
`RealColourTests` measures the demo project's player, stills, export and
camera file, `ProxyNoiseTests` how much proxies flicker at each quality,
and `ProxyRealMediaTests` today's proxies against all-intra ones: flicker,
keyframe ticks, size, build speed and seek times (all with
`TANDEM_REAL_MEDIA=1`). `ColourOnScreenTests` shows the
player and a still side by side in a window and reads them back from a
screen capture (`TANDEM_SCREEN=1`).
