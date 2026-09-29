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
| Shared library | anything, plus saved segments | Mike's own folder, `~/Movies/Tandem Library`, watched; used where it is | the nearest `tandem-licence.json` above a file | yes |
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

Originals are pinned while favourited or used in a project. Using a
downloaded, generated or import folder asset in a project copies it into the
project's `assets/` folder so projects stay self-contained. A different file
already there under the same name (a copy Mike reworked, or an older version
the timeline still plays) is never replaced: the new copy goes beside it.
Shared library assets are the exception: they're used where they are (see
below).

## The shared library

One visible folder on this Mac for everything Mike reuses across videos:
`~/Movies/Tandem Library` (Backblaze backs it up with the rest of the Mac).
Tandem > Settings… moves it; the choice is `sharedLibrary` in the asset
library's `settings.json`, and `$TANDEM_LIBRARY` moves it for one process.
An asset library anywhere other than the standard place (tests,
`$TANDEM_ASSETS_ROOT`) keeps its shared library inside itself, `<root>/Tandem
Library`, so nothing but the app touches the real one. The app makes the
folder the first time it opens after installing; opening the library
(the CLI, MCP, tests) never does.

```
~/Movies/Tandem Library/
  README.txt                what the folder is for
  Stickers/                 animated stickers: HEVC with alpha, WebM, GIF, WebP, Lottie
  Graphics/                 logos, lower thirds, overlays, stills (PNG, JPEG, SVG, MOV)
  Sound effects/
  Music/
  Looks/                    colour looks as .cube LUTs
  Fonts/                    TTF, OTF, TTC for titles
  Segments/<name>/          saved segments: segment.json and the media they play
```

Each folder has a README. Tandem never writes over one Mike edited.

**How it's indexed.** `SharedLibraryProvider` (source `shared`, the "Shared
library" chip) indexes the folder with the import folder machinery and
watches it with FSEvents, so a file dropped in shows up in its tab within a
second or so, searchable, with its thumbnail (made as its tile comes into
view) or waveform. A file's folder says what it is: anything in Music is
music however short, sounds in Sound effects are SFX, pictures in Stickers
are stickers, pictures in Graphics are overlays (logos when the name says
so; SVGs by their name), LUTs in Looks and fonts in Fonts. Subfolder names
become search words. `Segments/` and the READMEs aren't indexed. Asset IDs
are the path inside the library (`shared:Stickers/Party/Dance.gif`), so they
survive the library moving; a row whose file is somewhere else now is
described again. Licences: the nearest `tandem-licence.json` at or above a
file covers it (one in the library's top folder for Mike's own things,
another in `Sound effects/Envato/` for a subscription); without one a file
is Unknown licence, and the credits say so. The app registers the fonts in
`Fonts/` when it starts, so titles can use them without installing them for
the whole Mac.

**Reference, don't copy.** Using a shared asset (double-click, drag,
`tandem assets use shared:...`) adds the library's file to the project where
it is, by its absolute path, and records the use for the credits. Nothing is
copied into `assets/`, so improving a sticker or re-exporting an intro in
the library improves every project that uses it the next time it plays or
renders. Files a project can't play as they are (WebM, Lottie, SVG, TIFF,
FLAC, Ogg, animated GIF, WebP and PNG, QuickTime Animation) play from the
library's converted copy in `~/Library/Application Support/Tandem/Assets/
shared/<file>/`, which the watcher makes again when the file changes and a
project uses it (`refreshChangedSharedFiles`). Audio is measured for
loudness and a waveform but never copied to a 48 kHz WAV; LUTs and fonts
are used from the library too.

| Where the asset comes from | Using it in a project |
| --- | --- |
| Shared library (`shared:`) | referenced where it is; archiving copies it in |
| Import folder (`import:`) | copied into `assets/<kind>/` |
| Downloaded or generated (Noto, Iconify, SVGL, Fontsource, Pexels, Pixabay, ElevenLabs) | copied into `assets/<kind>/` |

**Segments.** A segment is a reusable bit of timeline (Mike's intro, outro,
like and subscribe, comment below): a `Template` of clips with their offsets,
the transitions between them and optional fields, plus copies of every file
those clips play and their LUTs, beside `segment.json` in `Segments/<name>/`, so it keeps working
whatever happens to the project it came from. Save one with Timeline > Save
selection as segment… (or right-click a clip), `tandem segments save` or
`segments_save`; they're in the Text tab under Segments. Inserting one is a
single `insertTemplate` whose media clips carry their media items, pointing
at the files in the segment's folder, so a project that lacks them gets them
added and one that has them reuses them. See AGENTS.md for the commands.

## Shared files and archived projects

Effects, title styles and transitions are data built into Tandem (packs
later), so a project never needs their files. A project can still end up
using files from outside its folder: the shared library's files and the
converted copies of them, a segment's media, an import's absolute paths, a
sound from another video's folder, a LUT picked from Downloads, a font a
title names that's only installed on this Mac. Archiving (File > Archive
project…, `tandem archive`, see ARCHITECTURE.md) copies all of those into
the project folder and points the project at the copies, so the folder opens
on another Mac (Bruce) with nothing missing:

- shared library files into `media/Tandem Library/<where they were in it>`
  (`media/Tandem Library/Stickers/Star.mov`, `media/Tandem Library/Segments/
  Intro/sting.wav`), and the converted copy of one beside where its original
  would go, named after it (`media/Tandem Library/Stickers/Spin.mov` for
  `Stickers/Spin.webm`);
- other media into `media/<the folder it was in>/`;
- LUTs into `assets/lut/` and fonts into `assets/font/`.

With `--to <folder>` it writes a standalone copy of the whole folder there
instead. Fonts are looked for with Core Text first (fonts in
`/System/Library` come with every Mac and aren't copied), then in the shared
library's `Fonts/` and among the library's downloaded fonts, which the CLI
doesn't register. `archive.json` records where each file came from, so the
licence trail (the catalogue's usage and licence tables) can still be
followed from an archived copy. A project opened on another Mac without
being archived finds its shared files again by relinking: `tandem relink`
and the app look in that Mac's shared library after the project folder.

## Normalising on import (tested on this Mac)

- Alpha video: AVFoundation can't open WebM. Decode VP9 WebM with ffmpeg's
  `libvpx-vp9` decoder (the built-in one drops alpha), write ProRes 4444, then
  convert to HEVC with alpha via `AVAssetExportPresetHEVCHighestQualityWithAlpha`
  (a 5 s sticker: 520 KB WebM, 23 MB ProRes 4444, 386 KB HEVC-alpha). Don't use
  ffmpeg's `hevc_videotoolbox` for alpha; its output fails to decode.
- WebM colour: sticker WebMs are usually untagged YUV made with the BT.601
  matrix, ffmpeg's and browsers' default for RGB (all 51 Filmora sticker
  WebMs on this Mac, 37 VP8 and 14 VP9, are). Left untagged, the export
  guesses wrong: a small red square came out (245, 33, 0), and one Filmora
  sticker's greens averaged 25 levels high. So the ProRes frames are tagged
  with ffmpeg `setparams`, keeping the WebM's own tags where AVFoundation
  reads them and otherwise using BT.709 primaries and transfer (web stickers
  are sRGB) with the BT.601 matrix. VP9's BT.601 flag shows up as `bt470bg`,
  a matrix code AVFoundation doesn't read, so it becomes `smpte170m`, the
  same matrix. Full range is scaled to limited, since a MOV can't mark ProRes
  full range. The HEVC copy keeps the BT.601 matrix, and the compositor
  reads it: the red square renders (251, 0, 0).
- QuickTime Animation and PNG in a MOV (Storyblocks, Motion Array and older
  VideoHive sticker packs): macOS 26 can't decode either, so they go the
  WebM way through ffmpeg and ProRes 4444 to HEVC with alpha
  (`HEVCTranscoder`, shared with project media). Animation and PNG frames
  are RGB: they're converted with the BT.709 matrix and tagged, because
  untagged, the export guessed SMPTE-C for a small picture and turned red
  orange. Without ffmpeg the import fails and says to install it.
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
  Downloaded and In this project. Source chips across the top, with Shared
  library first; shared assets carry a "Shared library" chip of their own.
- The Text tab's Segments lists the shared library's saved segments as
  sketches of their tracks. Segments sit with the Text tab's templates, not
  the Graphics tab, because they are templates: a group of clips that go in
  together, linked, often with words that change, and the built-in Like and
  Subscribe and Comment Below templates they generalise are already there.
  The Graphics tab is for single files placed one at a time.
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

- Decided 2026-09-29: Mike makes the Convex videos as a Convex employee, so
  Convex videos need company-channel licences (Epidemic Sound Business, not
  Pro; a Remotion company licence for Convex motion graphics). Tandem itself
  is for any project, so personal projects can use personal licences; the
  catalogue records each asset's licence so the credits and checks follow
  the project.
- The ElevenLabs key in the Keychain (`claude-code-music`) is restricted to
  music; turning on Sound Effects for it makes Generate work for SFX.
- Freesound stays off until its operator (UPF) agrees to commercial API use.
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
| Generate | `generate(GenerationRequest)` (keeps every paid take, lists failures), `remove(id)` for takes not kept |
| Use in a project | `use(id, in:projectID:)` gives an `AssetPlacement`; `editCommands(at:in:)` adds and places it |
| Description credits | `credits(for: project, in: folder).text()`, plus `warnings`; `licenceHistory(id)` for disputes |
| Import folders | `addImportFolder(url, licence: FolderLicence.presets["envato"])`, `rescanImportFolders()`, `watchImportFolders` |
| Shared library | `sharedLibrary`, `createSharedLibrary()`, `rescanSharedLibrary()`, `watchSharedLibrary`, `refreshChangedSharedFiles(report)`, `moveSharedLibrary(to:)`, `registerSharedFonts()`; `SharedLibrary.locate()` for other processes |
| Fonts | `registerFonts()` at launch, `AssetLibrary.registerFonts(in: project)` on open |
| Housekeeping | `prune()`, `evictUnpinnedFiles()`, `rebuildCatalogFromDisk()` |

An import folder's licence note is `tandem-licence.json` in the folder
(`source`, `licence`, `licenceClass`, `url`, `credit`, `certificate`,
`kind`, `notes`); presets exist for Envato, Mixkit, Pixabay, Sonniss, the
YouTube Audio Library, Epidemic, Artlist, Motion Array and Storyblocks.
Files in a folder without a note get the `unknown` licence class, and the
credits builder warns about them. Adding or correcting a note later
relicenses the folder's files on the next scan (the watcher sees the note
change), with a new snapshot for anything already used. A folder that
can't be read keeps its index rather than looking empty.

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
