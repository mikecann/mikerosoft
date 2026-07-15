# Video HQ

A native macOS command center for Mike's video-production workflows. Choose a
video in Finder or drag one into the window, preview it, then run the tools it
needs without leaving the app.

## Tools

- **Transcribe** runs the repo's existing `tools/transcribe/transcribe` launcher
  and saves `<video-name>.srt` beside the video.
- **Video Description** loads that transcript and uses Gemini through OpenRouter
  to save `<video-name>-description.txt` beside the video. If the transcript is
  missing, the app generates it first.

Existing sidecars are loaded whenever a video is opened. Description files are
compatible with the existing `video-description` CLI chat-log format, and the
app displays its latest Gemini response.

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

## Development

```bash
swift test --package-path tools/video-hq
bash tools/video-hq/setup_mac.sh
```

The app calls the transcribe launcher by its repo path and adds common Homebrew
locations to the child-process `PATH`, so it works when launched outside a
terminal.
