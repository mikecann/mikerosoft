# Video HQ

![Video HQ production command center](docs/header.jpg)

A native macOS command center for Mike's video-production workflows. Video HQ
treats each direct folder in `~/dev/convex/convex-videos` as one video project,
loads its script, and previews rendered MP4s from the project root.
The last selected project is restored the next time the app opens.

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
  then download the page as Markdown to `<project>/script.md`. Video HQ records
  the source page ID in YAML front matter, so later downloads become one-click
  syncs from the same Notion page. A Raw/Preview control switches between the
  source text and rendered Markdown. The metadata stays hidden in the app and
  its Teleprompter, which opens large, centered script text on the Elgato
  Prompter display.
- **New Project** is available from the project dropdown. It can create a blank
  local project or start from a project in the Convex Projects Notion database
  whose status is `Writing` or `Ready to Shoot`. The wizard suggests an editable
  kebab-case folder name and downloads Notion content as `script.md`.
- **Rough Cut Process** opens a separate source-recording workspace. It can copy
  a recording into the current project's `source` directory, reuse a saved
  word-timestamp transcript or SRT, detect silence-delimited sections, and ask
  Codex to review the complete transcript for valid sections, false starts, bad
  takes, and review items on a playable timeline. When `script.md` exists it is
  supplied as optional context, while the recording remains the source of
  truth. The same Codex pass also proposes likely joins for interrupted
  sentences. The rough-cut screen marks those joins on the timeline and provides the
  non-destructive preview, inline approval, rejection, and undo workflow
  directly. Dragging across the
  analysis timeline continuously scrubs the video and scrolls to highlight the
  matching detected section. The multi-select filters can show or hide any
  combination of detected types and are saved per analysis. Filtered-out clips
  remain faintly visible on the Dialogue track. Clicking a visible row plays
  from that clip through the remaining visible sequence with source gaps and
  silence skipped. Filters can also show only review items that still need an
  explicit decision. Every section has
  persistent **Auto**, **Keep**, and **Cut** controls. Step 1 is dedicated to
  choosing dialogue clips, resolving review calls, and approving or manually
  creating joins. Approved joins
  become expandable parent clips in the section list and matching boundaries
  for visual planning. Accepted clips can also be selected and joined or
  unjoined manually. Expanding a parent reveals its original child clips and
  their individual decisions. Merged previews
  trim to spoken word edges with small room-tone handles and a 40 ms audio
  crossfade, removing the thinking pause without clipping the sentence. Step 2
  lists only the accepted clip boundaries and shows the Visuals track above its
  Dialogue reference track. Both use the edited programme timeline, with
  rejected sections and source-recording gaps removed. Each clip can be assigned a talking-head,
  camera-cutout, B-roll, screen-recording, AI B-roll, or screencast layout with
  its media reference or generation note. Unassigned clips leave the Visuals
  track empty. **Suggest remaining visuals** asks Codex to learn from the
  existing human-authored choices and plan only the unassigned clips using the
  complete ordered dialogue. Suggested choices are saved with AI provenance,
  shown with dashed blocks on the Visuals timeline, and labelled in the clip
  list. Editing or applying one converts it into a human-authored choice. This
  process is saved beside the analysis. Filmora export
  currently writes the reviewed dialogue cut as a separate plan and new `.wfp`.
  Video HQ automatically finds a clean single-source Filmora project for the
  selected recording, so export only asks for the new project name and location.
  It never overwrites the planner output, source project, or an existing project.

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
- `/Users/m5-mike/dev/me/automate-filmora` for transcription, silence detection,
  and Filmora project generation
- Codex CLI, signed in locally, for Step 1 transcript review and join
  suggestions, plus Step 2 visual planning
- `OPENROUTER_API_KEY` in the repo-root `.env` for video descriptions
- `NOTION_API_KEY` in the repo-root `.env` for Notion search and script download

The Notion integration needs read-content access, and each script page must be
shared with the integration before it will appear in search or download by URL.
Set `VIDEO_HQ_PROJECTS_ROOT` before running `setup_mac.sh` if projects live
somewhere other than `~/dev/convex/convex-videos`.

The Rough Cut Process defaults to
`~/.local/share/mikerosoft-media-venv/bin/python` for independent-region Whisper
transcription. Override the planner checkout or Python environment before setup
with `VIDEO_HQ_FILMORA_AUTOMATION_ROOT` and `VIDEO_HQ_ROUGH_CUT_PYTHON`. Each
run is preserved under the project's `work/video-hq-rough-cut` directory with
its transcript, plan, review report, manual decision sidecar, and versioned
reviewed plans. Filmora export currently creates a new rough-cut project from a
clean source project that Video HQ discovers recursively inside the current
project folder. A recording still needs one Filmora-created clean project before
its first export. Merging into an existing edited project or inserting another
timeline is deliberately not supported until that Filmora operation has its own
controlled before-and-after format experiment.

## Development

```bash
swift test --package-path tools/video-hq
bash tools/video-hq/setup_mac.sh
```

The app calls the transcribe launcher by its repo path and adds common Homebrew
locations to the child-process `PATH`, so it works when launched outside a
terminal.
