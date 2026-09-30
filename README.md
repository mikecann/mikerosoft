# mikerosoft.app

A bunch of personalised desktop tools, tracked in git so changes
are versioned and the setup can be reproduced on any machine.

---

## A note if you found this repo

These tools are built for one person on one machine - mine. They make assumptions
about paths, hardware, and workflows that are specific to my setup. They probably
won't work for you out of the box.

If you want to use any of this, the recommended approach is:

1. Clone it
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
`worktree-tidy`. The copies under `tools/` here are on their way out.

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

## Quick start (fresh Windows machine)

```powershell
git clone <repo-url> C:\dev\me\mikerosoft.app
cd C:\dev\me\mikerosoft.app
copy .env.example .env        # then edit .env and fill in your API keys
powershell -ExecutionPolicy Bypass -File install.ps1
```

`install.ps1` loads `.env`, checks whether `C:\dev\tools` is on your `PATH`
and offers to add it automatically if not. It will error out if any required
API keys are missing.

---

## macOS setup

The root install flow is still **Windows-specific**. It creates `C:\dev\tools`
stubs, Explorer context menu entries, `.lnk` shortcuts, and other Windows-only
integration points.

For macOS, set tools up individually where mac support exists:

- `voice-type`:
  `bash tools/voice-type/setup_mac.sh`
- `mac-screenshot`:
  `bash tools/mac-screenshot/setup_mac.sh`
- `ghopen`:
  `bash tools/ghopen/setup_mac.sh`
- `worktrees` (needs [Bun](https://bun.sh) on your PATH): see [tools/worktrees/README.md](tools/worktrees/README.md) for setup (`install-to-path.sh` plus `~/.local/bin` on `PATH`).
- `taskbar`:
  `bash tools/taskbar/setup_mac.sh`
- `last-window-quits`:
  `bash tools/last-window-quits/setup_mac.sh`
- `mikey-mouse`:
  `bash tools/mikey-mouse/setup_mac.sh`
- `record-it`:
  `bash tools/record-it/setup_mac.sh`
- `phonebooth`:
  `bash tools/phonebooth/setup_mac.sh`
- `token-stats`:
  `bash tools/token-stats/setup_mac.sh`
- `record-meeting`:
  `bash tools/record-meeting/setup_mac.sh`
- `meeting-archive` (preview):
  `bash tools/meeting-archive/setup_mac.sh`
- `video-hq`:
  `bash tools/video-hq/setup_mac.sh`
- `telemprompit`:
  `bash tools/telemprompit/setup_mac.sh`
- `tandem`:
  `bash tools/tandem/setup_mac.sh`

At the moment that is the right shape for the repo. A fake "universal" root
installer would mostly be a wrapper around platform checks and per-tool scripts,
while still not covering the Windows-only integrations.

### macOS support matrix

| Tool | Status | Setup | Daily command | Notes |
| --- | --- | --- | --- | --- |
| `voice-type` | Supported | `bash tools/voice-type/setup_mac.sh` | `bash tools/voice-type/voice-type-mac.sh` | Push-to-talk voice typing on macOS. It runs from a stable Application Support installation rather than the active Git worktree. Diagnose it with `bash tools/voice-type/voice-type-mac.sh status`; open settings with `bash tools/voice-type/open-settings-mac.sh` or Spotlight `Voice Type` |
| `mac-screenshot` | Supported | `bash tools/mac-screenshot/setup_mac.sh` | `bash tools/mac-screenshot/restart.sh` | Global screenshot hotkey daemon for macOS. Optional login-item install via `bash tools/mac-screenshot/install-launchagent.sh` |
| `ghopen` | Supported | `bash tools/ghopen/setup_mac.sh` | `ghopen` | Opens the current repo on GitHub. With `gh` installed it opens the PR page first when the branch has one |
| `worktrees` | Supported | See [tools/worktrees/README.md](tools/worktrees/README.md) | `worktrees` | Needs `~/.local/bin` on `PATH` (or run `bash tools/worktrees/run.sh`). Uses the checkout you are in to find `tools/worktrees`; run `bun install` in that folder per clone if deps are missing |
| `taskbar` | Supported | `bash tools/taskbar/setup_mac.sh` | `taskbar restart` | Swift/AppKit taskbar for macOS. Run `bash install_mac.sh` if you want the `taskbar` launcher on `PATH` |
| `last-window-quits` | Supported | `bash tools/last-window-quits/setup_mac.sh` | `last-window-quits restart` | Menu-bar daemon that quits regular Dock apps after their final window closes. Requires Accessibility permission |
| `mikey-mouse` | Supported | `bash tools/mikey-mouse/setup_mac.sh` | `mikey-mouse restart` | Menu-bar daemon for side-button back/forward and smooth wheel scrolling. Requires Accessibility permission |
| `record-it` | Supported | `bash tools/record-it/setup_mac.sh` | `record-it` | SwiftUI + ScreenCaptureKit + AVFoundation recorder. Saves into the selected project's `source` folder |
| `phonebooth` | Supported | `bash tools/phonebooth/setup_mac.sh` | Launch `Phonebooth` from Spotlight, or `phonebooth` after `bash install_mac.sh` | Video works with any cabled iPhone or iPad. Control needs Xcode signed into a developer team and Developer Mode on the phone; the first connection builds a helper app for that phone |
| `token-stats` | Supported | `bash tools/token-stats/setup_mac.sh` | `token-stats` | SwiftUI dashboard that reads local Codex and Claude histories, pulls exact OpenRouter Activity API usage, and can import older CSV history |
| `record-meeting` | Supported | `bash tools/record-meeting/setup_mac.sh` | `record-meeting` | SwiftUI meeting audio recorder with diarized transcripts and optional Notion publishing |
| `meeting-archive` | Preview | `bash tools/meeting-archive/setup_mac.sh` | `meeting-archive` | Zoom capture, Bruce processing, and Notion publication validated. Chrome automatic capture is blocked pending the capture-mode decision; Teams and Slack remain live-unverified |
| `video-hq` | Supported | `bash tools/video-hq/setup_mac.sh` | Launch `Video HQ` from Spotlight or run `video-hq` | Project-first command center with Notion script import, rendered-video preview, transcription, and OpenRouter-powered descriptions |
| `telemprompit` | Supported | `bash tools/telemprompit/setup_mac.sh` | Launch `Telemprompit` from Spotlight, or `telemprompit` after `bash install_mac.sh` | Opens on the Elgato Prompter when it is connected, otherwise the main screen. Page Up/Down work from any app for clickers |
| `tandem` | Supported | `bash tools/tandem/setup_mac.sh` | `tandem app` to open the editor, `tandem help` for the agent CLI after `bash install_mac.sh` | Swift video editor. Projects are `.tandem` files in the video folder; `tandem mcp` serves agents |
| Everything else | Windows-only for now | Use `install.ps1` on Windows | Varies by tool | Most other tools still depend on Windows-specific shell integration, taskbar shortcuts, or Explorer context menus |

### Codex worktrees

The checked-in local environment at `.codex/environments/environment.toml`
bootstraps new Codex worktrees without changing global PATH entries, registering
daemons, or installing heavyweight per-tool runtime dependencies. It installs
the Bun packages under `tools/` and the website's npm dependencies.

Select the `mikerosoft` local environment once in Codex project settings. Codex
will then run `.codex/setup.sh` whenever it creates a worktree. Run the same
script manually to refresh dependencies in an existing worktree:

```bash
bash .codex/setup.sh
```

---

## How it works

```
C:\dev\me\mikerosoft.app\   <- this repo (source of truth)
    install.ps1
    tools\
        transcribe\
            transcribe.bat            <- real logic lives here
        scale-monitor\
            scale-monitor.ps1
            scale-monitor.vbs
            scale-monitor.bat
        ...

C:\dev\tools\                    <- on PATH; kept clean
    transcribe.bat               <- thin stub: sets EXEDIR, calls repo bat
    removebg.bat                 <- thin stub
    backup-phone.bat             <- thin stub
    Scale Monitor.lnk           <- taskbar shortcut -> repo .vbs
    ffmpeg.exe                   <- large binaries stay here, not in repo
    faster-whisper-xxl.exe
    ...
```

`install.ps1` generates the stubs. Each CLI gets a `.bat` for PowerShell/cmd
and an extensionless Git Bash shim that forwards to the `.bat`, so `ghopen`
works from Git Bash instead of needing `ghopen.bat`. The stubs point at
absolute paths inside the repo, so a `git pull` is all you ever need to pick up
changes to any tool. Re-run `install.ps1` only when **adding a new tool**.

---

## Updating a tool

```powershell
# 1. Edit the source file in the repo (e.g. tools\scale-monitor\scale-monitor.ps1)
# 2. Run the relevant automated tests
# 3. Smoke-test the real tool entry point if behaviour changed
# 4. Commit
cd C:\dev\me\mikerosoft.app
git add .
git commit -m "scale-monitor: describe the change"
```

No reinstall needed. The stub in `C:\dev\tools` already points at the repo file.

For `task-stats`, there is now a proper automated stack under [`tools/task-stats/tests/README.md`](tools/task-stats/tests/README.md), including unit tests, Windows integration tests, and opt-in screenshot + AI evaluation.

---

## Adding a new tool

### CLI tool (runs from terminal)

1. Create a subfolder: `mkdir my-tool`
2. Write the logic - a `.bat`, `.ps1`, or `.vbs` as appropriate
3. Add a stub entry in `install.ps1` using the `Write-BatStub` helper
4. Run `install.ps1` once
5. Commit everything

Stub pattern for a plain bat tool:

```powershell
Write-BatStub "my-tool" @"
@echo off
call "$RepoDir\tools\my-tool\my-tool.bat" %*
"@
```

Stub pattern when the tool needs the `C:\dev\tools` exe directory (like `transcribe`):

```powershell
Write-BatStub "my-tool" @"
@echo off
set "EXEDIR=%~dp0"
call "$RepoDir\tools\my-tool\my-tool.bat" %*
"@
```

Then in `my-tool.bat` use `%EXEDIR%` instead of `%~dp0` to find co-located binaries.

### Taskbar / GUI tool (like scale-monitor)

1. Create a subfolder with the `.ps1` and a `.vbs` launcher:

   **`my-tool.vbs`** (boilerplate - copy from `tools\scale-monitor\scale-monitor.vbs`):
   ```vbs
   Set objShell = CreateObject("WScript.Shell")
   objShell.Run "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & _
       CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName) & _
       "\my-tool.ps1""", 0, False
   ```

2. Add a shortcut entry in `install.ps1`:

   ```powershell
   $vbsPath      = "$RepoDir\tools\my-tool\my-tool.vbs"
   $shortcutPath = Join-Path $ToolsDir "My Tool.lnk"
   $wsh = New-Object -ComObject WScript.Shell
   $sc  = $wsh.CreateShortcut($shortcutPath)
   $sc.TargetPath       = "wscript.exe"
   $sc.Arguments        = "`"$vbsPath`""
   $sc.WorkingDirectory = "$RepoDir\tools\my-tool"
   $sc.Description      = "What this tool does"
   $sc.IconLocation     = "%SystemRoot%\System32\imageres.dll,109"
   $sc.Save()
   ```

3. Run `install.ps1`, then right-click the `.lnk` in `C:\dev\tools` -> **Pin to taskbar**.

---

## Notes

- Large binaries (`ffmpeg.exe`, `faster-whisper-xxl.exe`, `_models\`, etc.) live in
  `C:\dev\tools` and are **not** tracked here - too big for git.
- The `transcribe` stub injects `EXEDIR=C:\dev\tools` so the bat finds those binaries
  even though the logic now lives in this repo.
- If you move the repo, just run `install.ps1` again to regenerate the stubs with
  the new absolute path.
- `install.ps1` registers a "Mike's Tools" submenu in the Explorer right-click
  context menu for: common video extensions (transcribe), common image extensions
  (removebg), and folders / folder backgrounds (ghopen). All entries write to
  `HKCU\Software\Classes\...` and are safe to re-run - idempotent.
