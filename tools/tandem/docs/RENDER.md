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
| `RenderAssets.swift` | `RenderAssets`: proxies, mattes, isolated voice, loudness (from `MediaAnalysis`) |

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
  code values.
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
  file's measured loudness, capped at ±30 dB), `audio.gainDB` keyframes,
  fades (equal power), transitions, and voice isolation (original times
  1 - v plus the isolated file times v) all multiply into one envelope per
  segment, sampled finely enough that AVAudioMix's linear ramps sound
  smooth. AVAudioMix volumes above 1 work, so boosts are real.
- Every hard cut gets a 3 ms fade each side. Joins that continue the same
  media seamlessly (same file, contiguous source, same speed and gain) don't.
- Speed changes keep their pitch (spectral time-pitch).

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

## Measured (M5 Pro, release build)

| Job | Speed |
| --- | --- |
| 60 s 4K: screen + 50% cutout PiP camera with grade and shadow, voice, music, HEVC 80 Mbps | 15.8 s, 3.8x real time |
| Same at 30 Mbps | 3.7x |
| 60 s range of the imported v14 edit (494 clips) | 4.4x |
| The whole v14 edit, 11 min 7 s, HEVC 80 Mbps | 156 s, 4.3x, -14.09 LUFS, -1.1 dBTP (loudness passes about 5% of it) |
| Frame grab, 4K composite (first grab builds the composition) | 0.05 to 0.4 s |
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
- AVAssetWriter interleaves inputs: pushing all video before any audio
  stalls. Pull each input with `requestMediaDataWhenReady`.
- Calling `cancelReading()` on an AVAssetReader while another thread is in
  `copyNextSampleBuffer()`, or reading an output after its reader has been
  released, crashes. Export cancel is a flag: the encoder feed and muxers
  stop at the next sample, the feed thread (which holds the reader) is
  joined, and only then is the reader cancelled.

## Tests

`swift test --package-path tools/tandem` runs the render tests in about
5 s (the whole package in about 25 s):
pure maths and plan tests, golden-pixel compositor tests with stand-in
frames, end-to-end grabs and exports of synthetic movies (frame-number
stripes, a flash and a beep, tones with clicks). Real footage is opt-in:

```
TANDEM_REAL_MEDIA=1 swift test -c release -Xswiftc -enable-testing \
    --package-path tools/tandem --filter RealMediaTests
```

It reads the decision-models folder and the imported v14 project (never
writing there) and writes to `/private/tmp/claude-501/tandem-render/bench`.
