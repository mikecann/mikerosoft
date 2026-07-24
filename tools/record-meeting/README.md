# Record Meeting

A small always-on-top macOS recorder for online meetings. It captures both the
Mac's system audio and your microphone, saves an MP3, transcribes it locally,
detects speakers, asks you to name each detected voice, and writes a Markdown
transcript plus JSON metadata.

The recording window shows a live waveform. After processing, a review screen
lets you play or scrub the full recording, click transcript lines to seek, and
automatically highlights and scrolls to the line at the current playhead.

Completed meetings can also be added as pages in a single **Recorded Meetings**
Notion database.

## Requirements

- macOS 15 or newer
- Xcode or the Xcode Command Line Tools
- `ffmpeg` on `PATH`, in `~/.local/bin`, or installed with Homebrew
- A Hugging Face token with access accepted for
  [`pyannote/speaker-diarization-community-1`](https://huggingface.co/pyannote/speaker-diarization-community-1)
- Optional: a Notion integration token with insert-content access

## Install

```bash
bash tools/record-meeting/setup_mac.sh
bash install_mac.sh
record-meeting
```

The first script creates a dedicated Python environment under
`~/Library/Application Support/Record Meeting`, installs the transcription and
speaker-detection packages, builds the native app, and stages it at
`~/Applications/Record Meeting.app`.

macOS will ask for:

- **Screen & System Audio Recording**, for the remote side of a meeting
- **Microphone**, for your side of a meeting

Always test the first recording with headphones. Speaker playback can otherwise
feed back into the microphone and produce an echo in the saved MP3.

## Preferences

The default output directory is `~/RecordedMeetings`. Preferences let you
choose another directory, select a Whisper model, and configure Hugging Face
and Notion.

Tokens are stored in macOS Keychain. The other settings use `UserDefaults`.

### Notion setup

1. Create a Notion integration and give it **Insert content** capability.
2. Create or choose a normal Notion page that will contain the database.
3. Share that parent page with the integration.
4. In Record Meeting Preferences, paste the integration token and parent page
   URL.
5. Click **Create database**.

The app creates one database named **Recorded Meetings**, stores its data-source
ID, then creates one page per completed meeting. The page contains meeting
metadata and the full speaker-labelled transcript. The MP3 stays local; Notion
gets its local file path rather than uploading the audio.

If you already have a compatible database, paste its data-source ID instead.
Its properties must be named `Name`, `Started`, `Duration`, `Speakers`,
`Description`, `Audio file`, and `Transcript file`.

## Output

For a meeting named `Weekly planning`, Record Meeting writes:

```text
2026-07-24-143000-weekly-planning.mp3
2026-07-24-143000-weekly-planning.transcript.json
2026-07-24-143000-weekly-planning.transcript.md
2026-07-24-143000-weekly-planning.metadata.json
2026-07-24-143000-weekly-planning.sample-SPEAKER_00.mp3
```

The `.sample-*` clips are the short voice examples played by the speaker-naming
dialog. A hidden temporary `.mov` is used only while recording and is removed
after the MP3 and transcript JSON are safely written. If processing fails, that
temporary file is deliberately kept for recovery.

## Development

```bash
swift test --package-path tools/record-meeting
python3 tools/record-meeting/tests/test_processor.py
bash tools/record-meeting/restart.sh
```

After changing Swift code, use `restart.sh` so the signed app bundle remains
the process macOS associates with privacy permissions.
