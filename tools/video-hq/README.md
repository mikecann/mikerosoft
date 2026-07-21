# Video HQ

![Video HQ production command center](docs/header.jpg)

A native macOS command center for Mike's video-production workflows. Video HQ
treats each direct folder in `~/dev/convex/convex-videos` as one video project,
loads its script, and previews rendered MP4s from the project root.

If a project contains multiple root MP4 files, use the Render picker to switch
between them. Videos inside subfolders such as `source/` are deliberately
ignored by the automatic render picker. You can still choose or drag any video
manually.

## Tools

- **Transcribe** runs the repo's existing `tools/transcribe/transcribe` launcher
  and saves `<video-name>.srt` beside the video.
- **Video Description** loads that transcript and uses Gemini through OpenRouter
  to save `<video-name>-description.txt` beside the video. If the transcript is
  missing, the app generates it first.
- **Script** loads `script.md`, or another root Markdown/text file with `script`
  in its name. It can search shared Notion pages or accept a Notion page link,
  then download the page as Markdown to `<project>/script.md`. Its Teleprompter
  button opens large, centered script text on the Elgato Prompter display.
- **New Project** is available from the project dropdown. It can create a blank
  local project or start from a project in the Convex Projects Notion database
  whose status is `Writing` or `Ready to Shoot`. The wizard suggests an editable
  kebab-case folder name and downloads Notion content as `script.md`.

Existing sidecars are loaded whenever a video is opened. Description files are
compatible with the existing `video-description` CLI chat-log format, and the
app displays its latest Gemini response.

## Screenshots

### Script and render workspace

![Video HQ showing a project script beside its rendered video](docs/ss1.jpg)

### Timestamped transcript

![Video HQ showing a saved timestamped transcript](docs/ss2.jpg)

### YouTube description

![Video HQ showing a generated YouTube description](docs/ss3.jpg)

## Setup

```bash
bash tools/transcribe/deps.sh
bash tools/video-hq/setup_mac.sh
```

The setup script builds, signs, installs, and opens:

```text
~/Applications/Video HQ.app
```

You can then launch **Video HQ** from Spotlight, Raycast, Alfred, Finder, or
another macOS app launcher.

## Requirements

- macOS 13 or newer
- Swift from Xcode or Command Line Tools
- `ffmpeg` and `faster-whisper` for transcription
- `OPENROUTER_API_KEY` in the repo-root `.env` for video descriptions
- `NOTION_API_KEY` in the repo-root `.env` for Notion search and script download

The Notion integration needs read-content access, and each script page must be
shared with the integration before it will appear in search or download by URL.
Set `VIDEO_HQ_PROJECTS_ROOT` before running `setup_mac.sh` if projects live
somewhere other than `~/dev/convex/convex-videos`.

## Development

```bash
swift test --package-path tools/video-hq
bash tools/video-hq/setup_mac.sh
```

The app calls the transcribe launcher by its repo path and adds common Homebrew
locations to the child-process `PATH`, so it works when launched outside a
terminal.
