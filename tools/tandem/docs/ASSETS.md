# Asset library

Music, sound effects, stickers, overlays, B-roll, fonts, icons and logos in
one browser, from several sources, with the licence of every asset recorded.
Research from 2026-09-25 checked about 45 sources against their API, pricing
and licence pages; this is what it decided.

## What Mike uses (Filmora audit, 51 projects)

- A music bed in 42 projects (about -31 dB, 2 s fade out).
- Sound effects in 29 projects, 393 clips: whooshes, clicks, typing (about -15 dB).
- Animated stickers in 28 projects, 142 clips, 60 different ones, mostly used once.
- Title templates in 40 projects. Stock video in 18. LUTs in 1.

So music, SFX, stickers and titles come first. LUTs can wait.

## Licensing findings that shape the design

- Filmora's asset licence forbids using its assets outside Filmora, and a
  company channel needs Filmora's Business plan, which excludes the asset
  library. Nothing from Filmora's store moves to Tandem, and past use on the
  Convex channel may not have been covered. Tandem records the licence of
  every asset so this can't happen quietly again.
- Personal plans (Epidemic Creator, Artlist Social, Storyblocks Individual,
  Musicbed Individual) exclude company or client work.
- Few sources give an individual a download API: Epidemic Sound (personal key
  MCP endpoint), ElevenLabs, Freesound, Lordicon, Pexels, Pixabay, plus the
  free Iconify, Fontsource, Google Fonts, SVGL and Noto emoji. Envato,
  Artlist, Storyblocks, Motion Array, Musicbed, Mixkit and the YouTube Audio
  Library need an import folder instead (most ban scripted downloads).
- Dead or unusable: Tenor's API (shut down 30 Jun 2026), GIPHY (no caching,
  non-commercial user terms), LottieFiles free plan (5 downloads total),
  Shadertoy (defaults to non-commercial), Stability's local models (company
  revenue cap), SF Symbols (Apple UI only, never in videos).

## Sources

| Source | Kind | Access | Licence | V1 |
| --- | --- | --- | --- | --- |
| Import folders | anything | watched folders, one per library, with a licence note | per folder | yes |
| ElevenLabs sound effects | SFX, generated | `POST /v1/sound-generation`, key in Keychain service `elevenlabs` (needs the `sound_generation` permission turned on) | commercial on paid plans | yes |
| ElevenLabs music | music, generated | `POST /v1/music` | commercial on paid plans | yes |
| Noto animated emoji | stickers | no-key JSON index, Lottie and WebP | CC BY 4.0, credit | yes |
| Iconify | icons | `api.iconify.design`, no key, SPDX licence per set | per set; drop GPL, BY-SA, NC | yes |
| SVGL | tech logos | `svgl.app/api`, no key (has Convex) | trademarks | yes |
| Google Fonts / Fontsource | fonts | no key | OFL / Apache | yes |
| Pexels, Pixabay | stock video and images | free API keys | commercial, no credit | when keys exist |
| Freesound | SFX | token for previews, OAuth for originals | CC0 and CC BY only; API commercial use needs UPF's written OK | off until OK'd |
| Epidemic Sound | music and SFX | personal-key MCP endpoint | depends on plan tier | when Mike subscribes |
| Lordicon | animated icons | bearer API, PRO $8/mo | PRO: no credit | when Mike subscribes |

## Catalogue

- SQLite with FTS5 (system `sqlite3`), in `~/Library/Application Support/Tandem/Assets/catalog.sqlite`.
- Asset rows: provider, provider ID, kind (music, sfx, sticker, overlay, video,
  image, font, icon, logo, lut, title, transition), name, tags, duration, BPM,
  key, has alpha, size, sha256, state (remote, preview, original, normalised),
  credit line, favourite, last used.
- A licence table snapshots the terms (and any certificate) at download time.
- A usage table (asset, project, time) drives Recently used, "In this project",
  description credits and proof for Content ID disputes.

## Disk layout

```
~/Library/Application Support/Tandem/Assets/<provider>/<id>/
  meta.json  thumbnail.jpg  original.<ext>  normalised.<ext>  peaks.bin  loudness.json
~/Library/Caches/Tandem/AssetPreviews/     size-capped, least recently used goes first
```

Originals are pinned while favourited or used in a project. Using an asset in
a project copies it into the project's `assets/` folder so projects stay
self-contained.

## Normalising on import (tested on this Mac)

- Alpha video: AVFoundation can't open WebM. Decode VP9 WebM with ffmpeg's
  `libvpx-vp9` decoder (the built-in one drops alpha), write ProRes 4444, then
  convert to HEVC with alpha via `AVAssetExportPresetHEVCHighestQualityWithAlpha`
  (a 5 s sticker: 520 KB WebM, 23 MB ProRes 4444, 386 KB HEVC-alpha). Don't use
  ffmpeg's `hevc_videotoolbox` for alpha; its output fails to decode.
- Animated WebP and GIF: ImageIO decodes both with alpha and frame delays.
- Lottie: render offscreen with alpha (about 1.5 to 2.3 s for 140 frames at
  1024 square) into HEVC-alpha at import, so the renderer only sees video.
- SVG: `NSImage` renders SVG natively on macOS 26.
- Audio: decode at 48 kHz, measure LUFS and true peak, store waveform peaks.
  Default gains come from the audit: music -31 dB, SFX -15 dB.
- Fonts: register with `CTFontManagerRegisterFontURLs`.

## Browser

- Left rail: Music, SFX, Stickers, Overlays and B-roll, Titles, Transitions,
  Effects, LUTs, Fonts, Icons and logos. Each has Favourites, Recently used,
  Downloaded and In this project. Source chips across the top.
- Filters: duration, BPM, mood, has alpha, and licence (no credit, credit
  needed, subscription, AI).
- Tiles: hover-scrub for video and Lottie, audio plays from the hovered point
  of a waveform strip, Space for a big preview, hovering a transition, effect
  or title previews it on the selected clip.
- Downloads never block: insert the preview at once and swap in the original
  when it lands.
- The drop target decides: on a clip it applies, on a transition it
  replaces, on an empty track it makes a new clip.
- Similar (Freesound, Epidemic) and Generate (ElevenLabs variations, saving
  the prompt with the kept result).
- Credits panel builds the YouTube description credits.
- Agents get the same through `assets search`, `assets fetch`, `assets insert`
  and `assets credits` in the CLI and MCP.

## Decisions for Mike

- Is he making these as a Convex employee or freelance? That decides Epidemic
  Pro or Business and whether Remotion needs a Convex licence.
- Convex's headcount and revenue decide other plan tiers (Epidemic Business
  under $10M, Artlist and Envato Individual under 50 staff).
- Turn on `sound_generation` for the ElevenLabs key.
- Ask Freesound's operator (UPF) for written OK for commercial API use, or keep
  Freesound off.
- Optional: Envato Core at $16.50/mo is the cheapest broad library whose
  licence covers client work (import folder, no API).

## Implementation (TandemAssets)

Built on the `tandem-assets` branch as the `TandemAssets` library (depends
on Core, Media and `lottie-ios`). Everything goes through `AssetLibrary`;
results are Codable so the CLI and MCP can return them as JSON.

| Need | Call |
| --- | --- |
| Open the library | `AssetLibrary()` (default root), `installStarterContent()` once |
| Source chips and status | `providerInfo()` |
| Browse and filter | `search(AssetQuery)`, `.favourites()`, `.recentlyUsed()`, `.inProject(id)`, `.downloaded()` |
| Search the sources | `searchProviders(ProviderQuery, providerIDs:)`, `similar(to:)` |
| Hover previews and tiles | `previewFile(for:)`, `waveform(for:)`, `url(for:.thumbnail)` |
| Download and normalise | `fetch(id)` (licence snapshot, normalise, thumbnail) |
| Generate | `generate(GenerationRequest)`, `remove(id)` for takes not kept |
| Use in a project | `use(id, in:projectID:)` gives an `AssetPlacement`; `editCommands(at:in:)` adds and places it |
| Description credits | `credits(for: project).text()`, plus `warnings` |
| Import folders | `addImportFolder(url, licence: FolderLicence.presets["envato"])`, `rescanImportFolders()`, `watchImportFolders` |
| Fonts | `registerFonts()` at launch, `AssetLibrary.registerFonts(in: project)` on open |
| Housekeeping | `prune()`, `evictUnpinnedFiles()`, `rebuildCatalogFromDisk()` |

An import folder's licence note is `tandem-licence.json` in the folder
(`source`, `licence`, `licenceClass`, `url`, `credit`, `certificate`,
`kind`, `notes`); presets exist for Envato, Mixkit, Pixabay, Sonniss, the
YouTube Audio Library, Epidemic, Artlist, Motion Array and Storyblocks.
Files in a folder without a note get the `unknown` licence class, and the
credits builder warns about them.

Choices made while building it:

- GIF, WebP and Lottie frames go straight into HEVC with alpha through
  `AVAssetWriter` (`.hevcWithAlpha`, premultiplied), which decodes with its
  alpha intact and skips the ProRes step. WebM still goes ffmpeg
  (`libvpx-vp9`) to ProRes 4444 to the HEVC-with-alpha export preset.
- 48 kHz PCM audio and anything over 20 minutes is measured (loudness,
  peaks) but used as it is, so a long stock bed doesn't become a 2 GB WAV.
- SVGs rasterise to 2048 px on the long side, Lottie to 1024 px. Iconify
  icons come in white for dark screens (`AssetSettings.iconColour`).
- Thumbnails with transparency are `thumbnail.png`, the rest
  `thumbnail.jpg`.
- ElevenLabs music uses `music_v2_5` and `mp3_48000_192`, as Mike's music
  scripts do. Sound effects ask for `pcm_48000` and wrap it in WAV.
- Keys are read with the `security` tool, never `SecItemCopyMatching`, so
  a headless run can't stall on a Keychain dialog.
- `SVGRasteriser` imports AppKit (NSImage is the only SVG renderer); it
  draws into its own bitmap, off the main thread.

Live check on 2026-09-25: Noto, Iconify, SVGL and Fontsource work end to
end. ElevenLabs music works; sound effects are refused with
`missing_permissions` (the key lacks `sound_generation`), which the
provider remembers and shows in its status. Pexels, Pixabay and Freesound
have no keys on this Mac and are tested against fixtures.

Tests: `swift test --package-path tools/tandem --filter TandemAssetsTests`.
`TANDEM_LIVE_ASSETS=1` adds the free live tests; `TANDEM_LIVE_ELEVENLABS=1`
makes one paid sound effect and one paid music cue.
