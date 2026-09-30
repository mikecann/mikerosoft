# mikerosoft.app

A bunch of personalised desktop tools, and the [mikerosoft.app](https://mikerosoft.app)
website that shows them off. Each tool lives in its own repo, linked below.

---

## A note if you found this repo

These tools are built for one person on one machine - mine. They make assumptions
about paths, hardware, and workflows that are specific to my setup. They probably
won't work for you out of the box.

If you want to use any of this, the recommended approach is:

1. Pick a tool and clone its repo. Every tool's README starts with a prompt you can paste into your AI coding agent to do this for you
2. Open it in Cursor (or your AI editor of choice) and **ask the agent to explain what each tool does and what it assumes**
3. Customise freely - change paths, remove tools you don't need, add your own
4. Don't open issues or pull requests. These aren't general-purpose tools and I'm not maintaining them for anyone but myself. Fork and adapt.

> Don't blindly trust what's here. Have your AI agent read the code and tell you what it will do before you run it.

---

## Tools

Every tool now lives in its own public repo at `github.com/mikecann/<name>`,
with its own README, install script, tests and history. The table links to
them. Some were renamed on the way out: `video-to-markdown` is now
`youtube-to-markdown`, `removebg` is `cutout`, `remove-portrait` is
`video-cutout`, `mac-screenshot` is `snap-it`, `ctxmenu` is
`right-click-tidy`, `generate-from-image` is `img-remix` and `worktrees` is
`worktree-tidy`.

The [mikerosoft.app](https://mikerosoft.app) site in `website/` lists them all
and reads everything from those repos: source links, screenshots, dates and
each tool's changelog. It rebuilds daily, so a push to a tool repo shows up by
the next morning, or straight away from a manual run of the Deploy Website
workflow. To put a new tool on the site, create its repo, then add it to
`website/src/tools.ts` and `website/src/toolDetails.ts` and give it an icon
and a share image. `AGENTS.md` has the details.

| Name | Type | Description |
|---|---|---|
| <img src="https://cdn.jsdelivr.net/gh/mikecann/transcribe@main/docs/header.webp" width="220"><br>[transcribe](https://github.com/mikecann/transcribe) | CLI + context menu | Extract audio from a video and transcribe it via faster-whisper (CUDA with CPU fallback); right-click any video file in Explorer |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/youtube-to-markdown@main/docs/header.webp" width="220"><br>[youtube-to-markdown](https://github.com/mikecann/youtube-to-markdown) | CLI + context menu | Convert a YouTube URL to a markdown image-link and copy it to clipboard; right-click any `.url` Internet Shortcut in Explorer |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/cutout@main/docs/header.webp" width="220"><br>[cutout](https://github.com/mikecann/cutout) | CLI + context menu | Remove the background from an image using rembg / birefnet-portrait; right-click any image file in Explorer |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/video-cutout@main/docs/header.webp" width="220"><br>[video-cutout](https://github.com/mikecann/video-cutout) | CLI + context menu | Remove the background from a talking-head video and save a transparent MOV for Resolve; right-click any video file in Explorer |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/unmultitrack@main/docs/header.webp" width="220"><br>[unmultitrack](https://github.com/mikecann/unmultitrack) | CLI + context menu | Extract every video stream from an OBS/Aitum multi-track recording into separate editor-friendly files; right-click any video file in Explorer |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/img-upscale@main/docs/header.webp" width="220"><br>[img-upscale](https://github.com/mikecann/img-upscale) | CLI + context menu | Upscale an image locally with a quality-first transformer backend; right-click any image file in Explorer, choose `2x`, `4x`, `8x`, or `16x`, and keep the original file format |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/ghopen@main/docs/header.webp" width="220"><br>[ghopen](https://github.com/mikecann/ghopen) | CLI + context menu | Open the current repo on GitHub; opens the PR page if on a PR branch; right-click any folder in Explorer |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/right-click-tidy@main/docs/header.webp" width="220"><br>[right-click-tidy](https://github.com/mikecann/right-click-tidy) | GUI | Manage Explorer context menu entries - toggle shell verbs and COM handlers on/off without admin rights |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/color-picker@main/docs/header.webp" width="220"><br>[color-picker](https://github.com/mikecann/color-picker) | GUI | Pixie-style screen color picker; drag over the screen, preview the live color, and copy HEX, RGB, HSL, HLS, HSV, CMYK, or BGR |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/backup-phone@main/docs/header.webp" width="220"><br>[backup-phone](https://github.com/mikecann/backup-phone) | CLI | Back up an iPhone over MTP (USB) to a flat folder on disk |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/scale-monitor@main/docs/header.webp" width="220"><br>[scale-monitor](https://github.com/mikecann/scale-monitor) | Taskbar | Toggle Monitor 4 between 200% (normal) and 300% (filming) scaling |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/sleep-monitors@main/docs/header.webp" width="220"><br>[sleep-monitors](https://github.com/mikecann/sleep-monitors) | CLI + shortcut | Turn off all connected monitors until keyboard or mouse input wakes them |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/task-stats@main/docs/header.webp" width="220"><br>[task-stats](https://github.com/mikecann/task-stats) | Taskbar | Real-time NET/CPU/GPU/MEM sparklines overlaid on the taskbar |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/taskbar@main/docs/header.webp" width="220"><br>[taskbar](https://github.com/mikecann/taskbar) | Mac - taskbar | Windows-style taskbar for macOS with one bar per monitor, pinned apps, battery/stats/date widgets, an Elgato lights toggle, per-monitor overrides, and window avoidance |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/last-window-quits@main/docs/header.webp" width="220"><br>[last-window-quits](https://github.com/mikecann/last-window-quits) | Mac - menu bar | Quit normal Dock apps when their final window closes, while preserving minimized windows and normal save prompts |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/mikey-mouse@main/docs/header.webp" width="220"><br>[mikey-mouse](https://github.com/mikecann/mikey-mouse) | Mac - menu bar | Makes a normal mouse feel at home on macOS: side buttons go back and forward in Finder and Safari, and the notched wheel scrolls smoothly |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/record-it@main/docs/header.webp" width="220"><br>[record-it](https://github.com/mikecann/record-it) | Mac - GUI | Native SwiftUI screen and camera recorder with 4K/30 capture, project-aware output folders, and separate full-resolution files |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/phonebooth@main/docs/header.webp" width="220"><br>[phonebooth](https://github.com/mikecann/phonebooth) | Mac - GUI | Mirror and control several iPhones and iPads at once over USB, each in its own window: click to tap, drag to swipe, type to type |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/token-stats@main/docs/header.png" width="220"><br>[token-stats](https://github.com/mikecann/token-stats) | Mac - GUI | Native SwiftUI dashboard for Codex, Claude, and OpenRouter token usage with API-equivalent costs and shareable graph exports |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/record-meeting@main/docs/header.webp" width="220"><br>[record-meeting](https://github.com/mikecann/record-meeting) | Mac - GUI | Always-on-top meeting recorder with system audio + microphone capture, live waveform, synchronized transcript review, MP3 export, speaker-labelled transcription, and Notion publishing |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/meeting-archive@main/docs/header.webp" width="220"><br>[meeting-archive](https://github.com/mikecann/meeting-archive) | Mac - GUI (preview) | Camera-triggered meeting archive with a validated Zoom capture-to-Notion path; wider app coverage remains in validation |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/video-hq@main/docs/header.jpg" width="220"><br>[video-hq](https://github.com/mikecann/video-hq) | Mac - GUI | Native video-production command center with project and render discovery, Notion script import, transcription, and YouTube descriptions |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/tandem@main/docs/header.jpg" width="220"><br>[tandem](https://github.com/mikecann/tandem) | Mac - GUI + CLI | Native video editor that replaces Filmora for the Convex videos: record-it takes, cutout PiP, ripple editing, titles, music and SFX, a -14 LUFS export, and a CLI and MCP server so agents can edit the same project |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/telemprompit@main/docs/header.png" width="220"><br>[telemprompit](https://github.com/mikecann/telemprompit) | Mac - GUI | Teleprompter for the Elgato Prompter: paste notes or Notion bullets, click through them line by line or auto-scroll, with clicker keys that work from any app |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/voice-type@main/docs/header.webp" width="220"><br>[voice-type](https://github.com/mikecann/voice-type) | Taskbar + macOS daemon | Push-to-talk local voice transcription on Windows and macOS. On Apple Silicon it uses MLX for faster final transcription |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/video-titles@main/docs/header.webp" width="220"><br>[video-titles](https://github.com/mikecann/video-titles) | Context menu | Chat with an AI agent to ideate YouTube titles using the Compelling Title Matrix; right-click any video in Explorer (requires `OPENROUTER_API_KEY` in `.env`) |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/video-description@main/docs/header.webp" width="220"><br>[video-description](https://github.com/mikecann/video-description) | CLI + context menu | Generate a YouTube description via Gemini; auto-loads or generates a transcript, then drops into an interactive chat for revisions; right-click any video in Explorer (requires `OPENROUTER_API_KEY` in `.env`) |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/img-remix@main/docs/header.webp" width="220"><br>[img-remix](https://github.com/mikecann/img-remix) | Context menu | AI image generation from a reference image; right-click any image in Explorer, describe what you want, and Gemini generates a new image (requires `OPENROUTER_API_KEY` in `.env`) |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/svg-to-png@main/docs/header.webp" width="220"><br>[svg-to-png](https://github.com/mikecann/svg-to-png) | Context menu | Render an SVG to PNG at high resolution; right-click any `.svg` file in Explorer; output is always at least 2048px on its smallest dimension |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/img-to-svg@main/docs/header.webp" width="220"><br>[img-to-svg](https://github.com/mikecann/img-to-svg) | CLI + context menu | Convert a raster image to SVG vector using vtracer; right-click any image file in Explorer |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/copypath@main/docs/header.webp" width="220"><br>[copypath](https://github.com/mikecann/copypath) | CLI | Copy the absolute path of a file or folder to the clipboard; defaults to the current directory if no argument given |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/img-gen@main/docs/header.webp" width="220"><br>[img-gen](https://github.com/mikecann/img-gen) | GUI + context menu | Chat-style AI image generation using Gemini via OpenRouter; right-click any folder in Explorer; annotate generated images and refine iteratively; drag images out to Explorer to save (requires `OPENROUTER_API_KEY` in `.env`) |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/video-gen@main/docs/header.webp" width="220"><br>[video-gen](https://github.com/mikecann/video-gen) | GUI + context menu | Chat-style AI video generation using OpenRouter video models; right-click any folder in Explorer; model-aware settings, reference images, first/last frames, save or drag generated MP4s into the folder (requires `OPENROUTER_API_KEY` in `.env`) |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/face-swap@main/docs/header.webp" width="220"><br>[face-swap](https://github.com/mikecann/face-swap) | GUI + context menu | Swap a face from one image into another locally using InsightFace; right-click any image to pre-load the target, or launch it from Windows Search |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/snap-it@main/docs/header.webp" width="220"><br>[snap-it](https://github.com/mikecann/snap-it) | Mac - global hotkey daemon | Press `F11` to capture a screen region, auto-name it, copy it to the clipboard, and open it in Preview for annotation |
| <img src="https://cdn.jsdelivr.net/gh/mikecann/worktree-tidy@main/docs/header.webp" width="220"><br>[worktree-tidy](https://github.com/mikecann/worktree-tidy) | CLI (Bun) | Interactive `git worktree` cleanup: list linked checkouts, remove a subset, or remove all linked worktrees (macOS + Windows) |

---

## This repo

This repo is just the website now, in `website/`. It used to hold every tool
in a `tools/` folder too; each one moved to its own repo with its full history,
so older commits here still show how they started. See `AGENTS.md` for how the
site works and how to add a tool to it.

MIT licensed, like the tools.
