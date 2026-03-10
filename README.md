# mikerosoft.app

A bunch of personalised tools for Windows users, tracked in git so changes
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

| Name | Type | Description |
|---|---|---|
| <img src="tools/transcribe/docs/header.png" width="220"><br>[transcribe](tools/transcribe/README.md) | CLI + context menu | Extract audio from a video and transcribe it via faster-whisper (CUDA with CPU fallback); right-click any video file in Explorer |
| <img src="tools/video-to-markdown/docs/header.png" width="220"><br>[video-to-markdown](tools/video-to-markdown/README.md) | CLI + context menu | Convert a YouTube URL to a markdown image-link and copy it to clipboard; right-click any `.url` Internet Shortcut in Explorer |
| <img src="tools/removebg/docs/header.png" width="220"><br>[removebg](tools/removebg/README.md) | CLI + context menu | Remove the background from an image using rembg / birefnet-portrait; right-click any image file in Explorer |
| <img src="tools/ghopen/docs/header.png" width="220"><br>[ghopen](tools/ghopen/README.md) | CLI + context menu | Open the current repo on GitHub; opens the PR page if on a PR branch; right-click any folder in Explorer |
| <img src="tools/ctxmenu/docs/header.png" width="220"><br>[ctxmenu](tools/ctxmenu/README.md) | GUI | Manage Explorer context menu entries - toggle shell verbs and COM handlers on/off without admin rights |
| <img src="tools/backup-phone/docs/header.png" width="220"><br>[backup-phone](tools/backup-phone/README.md) | CLI | Back up an iPhone over MTP (USB) to a flat folder on disk |
| <img src="tools/scale-monitor/docs/header.png" width="220"><br>[scale-monitor](tools/scale-monitor/README.md) | Taskbar | Toggle Monitor 4 between 200% (normal) and 300% (filming) scaling |
| <img src="tools/task-stats/docs/header.png" width="220"><br>[task-stats](tools/task-stats/README.md) | Taskbar | Real-time NET/CPU/GPU/MEM sparklines overlaid on the taskbar |
| <img src="tools/voice-type/docs/header.png" width="220"><br>[voice-type](tools/voice-type/README.md) | Taskbar | Push-to-talk local voice transcription - hold Right Ctrl, speak, release to paste |
| <img src="tools/video-titles/docs/header.png" width="220"><br>[video-titles](tools/video-titles/README.md) | Context menu | Chat with an AI agent to ideate YouTube titles using the Compelling Title Matrix; right-click any video in Explorer (requires `OPENROUTER_API_KEY` in `.env`) |
| <img src="tools/video-description/docs/header.png" width="220"><br>[video-description](tools/video-description/README.md) | CLI + context menu | Generate a YouTube description via Gemini; auto-loads or generates a transcript, then drops into an interactive chat for revisions; right-click any video in Explorer (requires `OPENROUTER_API_KEY` in `.env`) |
| <img src="tools/generate-from-image/docs/header.png" width="220"><br>[generate-from-image](tools/generate-from-image/README.md) | Context menu | AI image generation from a reference image; right-click any image in Explorer, describe what you want, and Gemini generates a new image (requires `OPENROUTER_API_KEY` in `.env`) |
| <img src="tools/svg-to-png/docs/header.png" width="220"><br>[svg-to-png](tools/svg-to-png/README.md) | Context menu | Render an SVG to PNG at high resolution; right-click any `.svg` file in Explorer; output is always at least 2048px on its smallest dimension |
| <img src="tools/img-to-svg/docs/header.png" width="220"><br>[img-to-svg](tools/img-to-svg/README.md) | CLI + context menu | Convert a raster image to SVG vector using vtracer; right-click any image file in Explorer |
| <img src="tools/copypath/docs/header.png" width="220"><br>[copypath](tools/copypath/README.md) | CLI | Copy the absolute path of a file or folder to the clipboard; defaults to the current directory if no argument given |

---

## Quick start (fresh machine)

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

`install.ps1` generates the stubs. The stubs point at absolute paths inside
the repo, so a `git pull` is all you ever need to pick up changes to any tool.
Re-run `install.ps1` only when **adding a new tool**.

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
