![header](docs/header.webp)

# ![](icons/video-titles.png) video-titles

Interactive CLI chat tool for brainstorming YouTube video titles. Uses the Compelling Title Matrix framework as a system prompt and chats with Gemini via OpenRouter. Auto-detects (or generates) a transcript, then drops you into a back-and-forth chat session. Every exchange is logged to a `.jsonl` file next to the video.


## Screenshots

![video-titles screenshot](docs/ss1.png)


## Usage

**From File Explorer:**
Right-click any video file, choose **Mike's Tools > Video Titles**.
(On Windows 11, click "Show more options" first.)

**From the terminal:**

```
video-titles <video_file>
```

On launch the tool:

1. Looks for a `<videoname>.srt` alongside the video and loads it as context.
2. If no SRT exists, offers to run the `transcribe` tool to generate one.
3. Drops into an interactive chat. Type a message and press Enter to send.
4. Type `quit` to exit.

Each exchange is appended as plain text to `<videoname>-titles.txt` in the same folder as the video.

## Dependencies

| Requirement          | Notes                                                                   |
| -------------------- | ----------------------------------------------------------------------- |
| `OPENROUTER_API_KEY` | Set in `.env` at the repo root. Get a key at https://openrouter.ai/keys |
| `transcribe` tool    | Only needed if you want auto-generated transcripts (optional)           |

No npm, no binaries - just PowerShell and an API key.

## Model

Uses `google/gemini-3.1-pro-preview` via the OpenRouter API (`https://openrouter.ai/api/v1/chat/completions`).
To change the model, edit the `$MODEL` constant at the top of `video-titles.ps1`.