![header](docs/header.webp)

# ![](icons/video-description.png) video-description

Interactive CLI chat tool for generating YouTube video descriptions. Auto-detects (or generates) a transcript, then fires off an initial description request to Gemini and drops you into a back-and-forth chat session. Every exchange is logged to a `.txt` file next to the video so the conversation can be resumed on the next run.


## Screenshots

![video-description screenshot](docs/ss1.png)


## Usage

**From File Explorer:**
Right-click any video file, choose **Mike's Tools > Video Description**.
Right-click inside a folder (background), choose **Mike's Tools > Video Description** to pick from videos in that folder.
(On Windows 11, click "Show more options" first.)

**From the terminal:**

```
video-description <video_file>
video-description <folder>
```

On launch the tool:

1. Looks for a `<videoname>.srt` alongside the video and loads it as context (timestamps preserved).
2. If no SRT exists, offers to run the `transcribe` tool to generate one.
3. Auto-fires an initial description request to Gemini.
4. Drops into an interactive chat for revisions. Type a message and press Enter to send.
5. Type `quit` to exit.

On subsequent runs from the same folder, the previous conversation is restored and the last exchange is shown.

## Output

Each exchange is appended as plain text to `<videoname>-description.txt` in the same folder as the video. The final description in the file is the latest version ready to copy into YouTube Studio.

## What Gemini produces

Each response contains, in this order:

1. **Description** - keyword-rich, third-person, developer-focused summary
2. **Timestamps** - clean `[HH:MM:SS] Title` list inferred from the transcript
3. **Resources** - any links you provide (or a placeholder to fill in)
4. **Hashtags** - 8-15 relevant hashtags for the tech stack and topic
5. **Titles** - three alternative video title options

## Iterating

After the first response you can ask things like:

- `make the description more concise`
- `add a mention of the Convex docs link: https://docs.convex.dev`
- `the timestamps are off - section 3 starts at 4:20`
- `regenerate the hashtags with a focus on TypeScript`

## Dependencies

| Requirement          | Notes                                                                   |
| -------------------- | ----------------------------------------------------------------------- |
| `OPENROUTER_API_KEY` | Set in `.env` at the repo root. Get a key at https://openrouter.ai/keys |
| `bun`                | Install via `winget install oven-sh.bun` or https://bun.sh              |
| `transcribe` tool    | Only needed if you want auto-generated transcripts (optional)           |

## Model

Uses `google/gemini-3.1-pro-preview` via the OpenRouter API.
To change the model, edit the `MODEL` constant at the top of `index.ts`.