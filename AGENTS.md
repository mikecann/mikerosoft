# Agent guidance - mikerosoft.app

Instructions for AI agents (Cursor, etc.) working in this repo.

---

## Repo purpose

A bunch of personalised desktop tools. Each tool lives in its own
subfolder. `install.ps1` wires everything into `C:\dev\tools` (which is on
PATH) via thin stub `.bat` files or `.lnk` shortcuts.

---

## Key rules

- **Never put source files directly in `C:\dev\tools`.** All logic belongs in
  this repo under the appropriate tool subfolder. `C:\dev\tools` only ever
  gets auto-generated stubs from `install.ps1`.
- **Large binaries stay in `C:\dev\tools`**, not here. Never commit `.exe` or
  `.dll` files. They are gitignored.
- **Use test-first development for non-trivial changes.** Write or update the
 automated test first, then implement the change until the test passes. If the
 current code has no clean test seam, extract one first and then add the test.
- **When behaviour changes, rerun the relevant tests.** If your change affects
 expectations, UI copy, layout, persistence, startup behaviour, or any tested
 contract, update the tests and rerun them instead of assuming the old tests
 are still valid.
- **Test before committing.** Run the relevant automated tests first, then run
 the actual script/tool to verify it works. For `.ps1` scripts, run them
 directly with PowerShell. For `.vbs` launchers, run via `wscript.exe`. Check
 exit codes.
- **No console windows for GUI/taskbar tools.** Use the `.vbs` launcher pattern
  (see `tools\scale-monitor\scale-monitor.vbs`) which calls `wscript.exe` with
  window style 0. Never launch PowerShell from a taskbar shortcut without a
  `.vbs` wrapper — it causes a CMD window to flash.
- **ASCII encoding for `.bat` files.** Always write bat files with
  `-Encoding ASCII` in PowerShell, or avoid non-ASCII characters entirely.
  Em dashes and curly quotes in string literals will cause parse errors.
- **Re-run `install.ps1` after adding a new tool.** Editing an existing tool
  never requires reinstall — stubs point at the live repo files.

---

## deps.ps1 convention

Each tool can have an optional `<name>\deps.ps1` that installs or checks its
dependencies. Rules:

- **Idempotent** — check before installing; safe to run multiple times.
- **Self-contained** — must work when run directly (`.\tools\transcribe\deps.ps1`).
- **Clear output** — use `Write-Host` with colour so the user sees what happened.
- For large manual-download binaries (e.g. `ffmpeg.exe`), just check and print
  a helpful message; don't try to auto-download.
- For Python packages use `pip install`; check `python -c "import pkg"` first.
- For system tools (e.g. Docker) use `Get-Command` to detect and warn if absent.

`install.ps1` auto-discovers every `*/deps.ps1` under the repo root and runs
them in alphabetical order. Pass `-SkipDeps` to skip this step.

---

## Adding a CLI tool

1. `mkdir <name>` in the repo root
2. Write `<name>\<name>.bat` (or `.ps1`) with the full logic
3. If the tool needs `ffmpeg.exe`, `faster-whisper-xxl.exe`, or other large
 binaries that live in `C:\dev\tools`, accept `EXEDIR` as an env var
 and fall back: `if not defined EXEDIR set "EXEDIR=%~dp0"`
4. If the tool has external dependencies, write `<name>\deps.ps1`
5. Add a `Write-BatStub` call in `install.ps1`
6. Run `install.ps1`
7. Smoke-test: open a new terminal and call the command by name
8. Update `README.md` to add the tool to the list with its icon.
9. Add a `tools/<name>/icons/<name>.png` icon (e.g. from famfamfam-silk).
10. Update `website/src/index.js` to add the tool to the site.
11. Commit

## Adding a taskbar / GUI tool

1. `mkdir <name>` in the repo root
2. Write `<name>\<name>.ps1` with WinForms or notification logic
3. Copy `tools\scale-monitor\scale-monitor.vbs` as `tools\<name>\<name>.vbs` and update
 the filename reference inside it
4. If the tool has external dependencies, write `<name>\deps.ps1`
5. Add a shortcut block in `install.ps1` (see the `scale-monitor` section)
6. Run `install.ps1`
7. Test via `wscript.exe "C:\dev\me\mikerosoft.app\tools\<name>\<name>.vbs"`
8. Right-click the generated `.lnk` in `C:\dev\tools` → Pin to taskbar
9. Update `README.md` to add the tool to the list with its icon.
10. Add a `tools/<name>/icons/<name>.png` icon (e.g. from famfamfam-silk).
11. Update `website/src/index.js` to add the tool to the site.
12. Commit

---

## Editing an existing tool

1. Edit the file in this repo directly (e.g. `tools\scale-monitor\scale-monitor.ps1`)
2. For non-trivial behaviour changes, write or update the automated tests first
3. If the change affects an existing test expectation, update that test or test fixture in the same change
4. Run the relevant automated tests again after the implementation change, then smoke-test it: run via `wscript.exe` (GUI) or directly with PowerShell (CLI)
5. Commit - no reinstall needed

---

## File structure

```
mikerosoft.app\
├── AGENTS.md                  ← you are here
├── README.md
├── install.ps1                ← generates stubs + runs deps.ps1; re-run when adding tools
├── install_mac.sh             ← symlinks POSIX launchers; optional --with-bun-install
├── .gitignore
├── tools\
    ├── lib\
    │   ├── run-transcribe.ts      ← shared: Windows transcribe.bat vs POSIX transcribe
    │   └── PrompterKit\           ← Swift package: Elgato Prompter display lookup + DisplayLink switch (taskbar, video-hq, telemprompit)
    ├── ghopen\
    │   ├── ghopen.bat             ← opens GitHub repo or PR page in browser
    │   └── deps.ps1               ← checks gh CLI (optional but recommended)
    ├── backup-phone\
    │   ├── backup-phone.bat
    │   ├── backup-phone.ps1
    │   └── deps.ps1               ← pip install pillow pillow-heif
    ├── removebg\
    │   ├── removebg.bat
    │   └── deps.ps1               ← pip install rembg[gpu]
    ├── scale-monitor\
    │   ├── scale-monitor.ps1     ← WinForms popup UI + registry toggle
    │   ├── scale-monitor.vbs     ← silent launcher (no window flash)
    │   └── scale-monitor.bat     ← thin bat wrapper (not used directly)
    ├── task-stats\
    │   ├── task-stats.csproj      ← MSBuild project (no SDK needed)
    │   ├── Native.cs              ← Win32 P/Invoke + NVML declarations
    │   ├── Settings.cs            ← JSON-backed settings
    │   ├── Metrics.cs             ← CircularBuffer + PerformanceCounter/NVML sampling
    │   ├── OverlayForm.cs         ← layered window, rendering, hit-test, menu
    │   ├── SettingsForm.cs        ← tabbed settings dialog
    │   ├── App.cs                 ← DarkRenderer + App entry point
    │   ├── icons\                 ← famfamfam silk icons (CC BY 2.5) embedded as manifest resources
    │   ├── task-stats.ps1         ← PS launcher: loads pre-built DLL, calls App::Run()
    │   ├── task-stats.vbs         ← silent launcher (no console window)
    │   ├── build.bat              ← builds via MSBuild.exe → %LOCALAPPDATA%\task-stats\task-stats.dll
    │   ├── build-and-run.bat      ← kill + build + launch in one step (daily dev command)
    │   ├── kill.bat               ← kills running task-stats by command-line pattern
    │   └── deps.ps1               ← checks nvml.dll present (NVIDIA GPU monitoring)
    ├── worktrees\
    │   ├── index.ts               ← Bun + inquirer: interactive git worktree cleanup
    │   ├── worktrees              ← POSIX launcher (mac): git top-level + bun run
    │   ├── install-to-path.sh     ← copies launcher to ~/.local/bin
    │   ├── deps.ps1               ← bun install in this folder (Windows install.ps1)
    │   └── README.md
    ├── transcribe\
    │   ├── transcribe.bat         ← Windows: %EXEDIR% ffmpeg.exe + faster-whisper-xxl.exe
    │   ├── transcribe             ← macOS/Linux: bash → transcribe.py
    │   ├── transcribe.py          ← ffmpeg on PATH + pip faster-whisper
    │   ├── deps.ps1               ← Windows: checks C:\\dev\\tools exes + _models
    │   └── deps.sh                ← macOS: brew ffmpeg + pip faster-whisper
    ├── 3d-viewer\                 ← Electrobun; 3d-viewer (mac) same as bun start + GLB_FILE
    ├── face-swap\                 ← Electrobun; face-swap (mac) loads .env + bun dev
    └── img-gen\                   ← Electrobun; img-gen (mac) loads .env + bun dev
```

---

## Important paths

| Path | What it is |
|---|---|
| `C:\dev\me\mikerosoft.app\` | This repo |
| `C:\dev\tools\` | On PATH; holds stubs + large exe binaries |
| `C:\dev\tools\ffmpeg.exe` | Used by transcribe |
| `C:\dev\tools\faster-whisper-xxl.exe` | Used by transcribe |
| `C:\dev\tools\_models\` | Whisper model files |

---

## task-stats specifics

Replacement for TrafficMonitor / XMeters. Displays NET↑/↓, CPU, GPU, MEM as
sparkline graphs on the right side of the Windows taskbar, positioned just to
the LEFT of the system clock (detected via `TrayNotifyWnd`).

### Icons
Right-click menu icons come from the **famfamfam silk icon set** (Mark James, CC BY 2.5).
Source: https://www.famfamfam.com/lab/icons/silk/
The PNGs live in `task-stats\icons\` and are embedded into the DLL as manifest resources via
`<EmbeddedResource Include="icons\*.png" />` in `task-stats.csproj`.

### Architecture
- **Requires .NET 10 SDK for builds.** Build with `dotnet build`; runtime host is `net10.0-windows`.
- Project file: `task-stats\task-stats.csproj` (SDK-style, targets `net10.0-windows`, embeds `icons\*.png` as manifest resources).
- Compiled output is cached at `%LOCALAPPDATA%\task-stats\task-stats.exe`.
- `task-stats.vbs` is the primary silent launcher and starts the built EXE directly.
- `task-stats.ps1` is only a compatibility wrapper around the EXE, not the primary host.

### Dev workflow
```
cd task-stats
.\build-and-run.bat    # kill old instance + compile + launch
```
After code changes to any `.cs` file, just re-run `build-and-run.bat`.

### Test workflow
```
cd tools\task-stats
.\run-unit-tests.bat
.\run-integration-tests.bat
.\run-tests.bat
.\run-e2e-tests.bat
```

- `run-unit-tests.bat` covers pure logic like layout math, formatting, buffers,
  and settings round-trips.
- `run-integration-tests.bat` covers Windows-backed behaviour like settings
  persistence, startup registration, and live metric sampling contracts.
- `run-tests.bat` runs everything except the AI screenshot judge.
- `run-e2e-tests.bat` captures deterministic overlay screenshots and then uses
  OpenRouter vision to check them. This is opt-in because it costs money and
  depends on external services.
- For `task-stats`, prefer deterministic fake-data tests before relying on
  manual tray screenshots.
- If you change rendering or layout, run `run-e2e-tests.bat` before committing.
- If you change behaviour covered by tests, rerun the affected test command
  after the implementation change, not just before it.

### Key implementation details
- `OverlayForm` is a frameless `WS_POPUP` + `HWND_TOPMOST` WinForms Form.
- `TransparencyKey = BackColor` makes the dark background see-through so the
  taskbar shows through. Only sparklines and text are visible.
- Position: `TrayLeftEdge()` finds `Shell_TrayWnd → TrayNotifyWnd` via
  `FindWindowEx` + `GetWindowRect` to know where the clock starts.
- `StartPosition = Manual` is critical - without it, `Show()` overrides the
  position set in the constructor.
- Z-order: a 100 ms timer re-asserts `HWND_TOPMOST` + a `WM_WINDOWPOSCHANGED`
  handler does it immediately on any z-order change.
- GPU: NVML P/Invoke (`nvml.dll`) - no `nvidia-smi` subprocess.
- CPU: `PerformanceCounter("Processor", "% Processor Time")` - aggregate +
  per-core for the XMeters-style grid mode.
- Settings: `%LOCALAPPDATA%\task-stats\settings.json` (richly commented JSON).
  Right-click overlay → Settings to change via UI.

### Known limitations
- In exclusive-fullscreen mode (rare - most modern games use borderless) the
 overlay may briefly disappear and return within ~100 ms.

### Important paths for task-stats
| Path | What it is |
|---|---|
| `tools\task-stats\task-stats.csproj` | SDK-style .NET project file |
| `tools\task-stats\src\Native.cs` | Win32 P/Invoke + NVML declarations |
| `tools\task-stats\src\Settings.cs` | JSON-backed settings |
| `tools\task-stats\src\Metrics.cs` | CircularBuffer + PerformanceCounter/NVML sampling |
| `tools\task-stats\src\OverlayForm.cs` | Layered window rendering + hit-test + menu |
| `tools\task-stats\src\SettingsForm.cs` | Tabbed settings dialog |
| `tools\task-stats\src\App.cs` | DarkRenderer + App entry point |
| `tools\task-stats\src\Program.cs` | EXE entry point and single-instance guard |
| `tools\task-stats\icons\` | famfamfam silk icons - CC BY 2.5, https://www.famfamfam.com/lab/icons/silk/ |
| `tools\task-stats\build.bat` | Builds via `dotnet build` |
| `tools\task-stats\build-and-run.bat` | Full dev cycle: kill + build + launch |
| `tools\task-stats\kill.bat` | Kills `task-stats.exe` and legacy PowerShell-hosted instances |
| `%LOCALAPPDATA%\task-stats\task-stats.exe` | Compiled output (not in git) |
| `%LOCALAPPDATA%\task-stats\settings.json` | User settings (not in git) |
| `C:\Windows\System32\nvml.dll` | NVIDIA GPU monitoring (ships with drivers) |

---

## voice-type specifics

Push-to-talk voice transcription tool. Hold Right Ctrl to record, release to transcribe and inject text into the active window.

### Dev workflow

After any code change to `tools\voice-type\voice-type.py`, restart with:

```
cd tools\voice-type
restart.bat
```

`restart.bat` kills all existing instances then relaunches via `voice-type.vbs`.
Always use this - never launch `voice-type.py` directly with `Start-Process` or
`python`, as that bypasses the kill step and leaves multiple instances running.

After restarting, confirm a clean startup:
```powershell
Get-Content voice-type\voice-type.log | Select-Object -Last 5
```

To verify exactly one instance is running:
```powershell
cmd /c "tasklist /FO CSV" | ConvertFrom-Csv | Where-Object { $_."Image Name" -like "*python*" }
```

**Rules:**
- Always kill all instances before launching a new one. Never leave multiple instances running.
- Always launch via `restart.bat` or `voice-type.vbs` - never directly with `Start-Process python ...`.
- After launching, tail the log to confirm a clean startup.
- On macOS, `setup_mac.sh` must install `~/Applications/Voice Type.app` via
  `install-spotlight-app.sh`; the app is the Spotlight entry point for opening
  settings. Building only `.venv/bin/Voice Type` is not sufficient for Spotlight.

---

## mac-screenshot specifics

Global hotkey screenshot daemon for macOS. Press F12 to enter
selection-capture mode, save to `~/Desktop/Screenshots` with a timestamp name,
copy to clipboard, and open in Preview for annotation.

### Dev workflow

After any code change to `tools/mac-screenshot/mac-screenshot.py`, restart with:

```bash
bash tools/mac-screenshot/restart.sh
```

Confirm a clean startup:
```bash
tail -f ~/Library/Logs/mac-screenshot.log
```

### First-time setup

```bash
bash tools/mac-screenshot/setup_mac.sh
bash tools/mac-screenshot/install-launchagent.sh
```

Then grant Accessibility permissions:
- System Settings > Privacy & Security > Accessibility
- Add Terminal (or whichever app runs the Python process) and enable it

### Key files

| Path | What it is |
|---|---|
| `tools/mac-screenshot/mac-screenshot.py` | Daemon - global hotkey listener + screenshot logic |
| `tools/mac-screenshot/setup_mac.sh` | One-time setup: creates `.venv`, installs `pynput` |
| `tools/mac-screenshot/restart.sh` | Kill + relaunch (daily dev command) |
| `tools/mac-screenshot/kill.sh` | Kill running instance |
| `tools/mac-screenshot/install-launchagent.sh` | Install as login item via LaunchAgent |
| `tools/mac-screenshot/uninstall-launchagent.sh` | Remove login item |
| `~/Library/Logs/mac-screenshot.log` | Runtime log (not in git) |
| `~/Desktop/Screenshots/` | Default save directory |

### Configuration

Edit the constants at the top of `mac-screenshot.py`:
- `HOTKEY` - defaults to `<f12>`
- `SAVE_DIR` - defaults to `~/Desktop/Screenshots`

### Rules

- Always use `restart.sh` to restart - never launch the script directly, it leaves stale instances.
- After any code change, run `restart.sh` and tail the log to confirm clean startup.

---

## record-it specifics

Native SwiftUI screen and camera recorder for macOS. ScreenCaptureKit records the
selected display and system audio. AVFoundation records the selected camera and
default microphone. When both are selected, each source gets its own full-resolution
HEVC `.mov` file.

### Dev workflow

After any Swift change, run the tests and restart the staged app:

```bash
swift test --package-path tools/record-it
bash tools/record-it/restart.sh
```

Always launch the staged `~/Applications/Record It.app`. Do not run the raw
SwiftPM executable for permission testing because macOS keys Screen Recording,
Camera, and Microphone permissions to the signed app bundle.
`build-app.sh` signs with the first `Apple Development` identity in the keychain.
That certificate's default designated requirement (bundle ID plus certificate)
stays the same across rebuilds, so TCC permissions persist without help.
The stable-requirement workaround only applies when no Apple Development
identity exists. Then `build-app.sh` falls back to an ad-hoc signature and adds
an explicit `identifier "com.mikerosoft.record-it"` designated requirement.
Do not remove it: the default ad-hoc requirement is the changing binary hash
and invalidates TCC permissions after every rebuild. Grants made under that
ad-hoc requirement carried over to the certificate-signed app on this Mac
without a new prompt. If macOS does prompt once after switching, approve it and
later rebuilds keep the grant.

### Key behaviour

- `HG584T05` is the default display and is kept at 1920 × 1080 HiDPI on this
  machine, producing a native 3840 × 2160, 30 fps recording.
- Screen output always preserves the selected display's active framebuffer.
  Record It does not change display modes or upscale screen recordings.
- Screen video uses variable-duration frames. Do not restore the old catch-up
  loop that manufactured every missing 30 fps frame: a long static interval at
  4K can permanently backlog the hardware encoder while audio continues.
- A screen-callback and encoder-backpressure watchdog stops failed recordings
  visibly. Diagnostics are written to `~/Library/Logs/Record It/record-it.log`.
- While recording, the configuration form becomes a live dashboard sourced
  from `MovieWriter` progress. It shows accepted video/audio sample counts,
  media duration, file size, output name, encoder, resolution, and health for
  each active source. Both screen and camera pipelines warn after three seconds
  without activity and stop after ten seconds or 60 rejected video samples.
- The first 4K/30-capable camera is selected by default. On this machine that is
  `Razer Kiyo Pro Ultra`.
- The camera **Preview…** button opens the selected camera in an uncropped 16:9
  titled window that can move and resize, and remembers its frame. It captures
  no audio, writes no file, and stops the camera session before closing.
- The file name field defaults to the timestamp prefix, accepts an override
  without `.mov`, and resets to a fresh timestamp after every recording.
- The selected Screen, Camera, or Both recording mode persists in `UserDefaults`
  and is restored on the next launch.
- Screen audio defaults to ScreenCaptureKit system playback and can be disabled.
  It does not use a microphone.
- Camera audio is independently selectable and defaults to the first microphone
  whose name contains `Yeti`.
- The encoder menu lists only available VideoToolbox H.264 and HEVC hardware
  encoders. CBR, CQP, and VBR controls are capability-filtered and persist in
  `UserDefaults` between launches.
- Screen recordings use the **Screen quality** preset, default Edit Master
  (VideoToolbox `kVTCompressionPropertyKey_Quality` 0.95). It replaces the
  shared rate control for the screen only; the camera keeps CBR/CQP/VBR.
  Do not route screen capture back through a fixed QP: CQP 30 produced
  under 1 Mbps screen files with blocky gradients at 2-3× zoom.
- Projects come from `~/dev/convex/convex-videos`, newest creation date first.
- Project recordings go to `<project>/source`; No Project goes to
  `~/Movies/record-it-output`.
- Screen and camera outputs are separate files so neither source is scaled into
  a combined canvas.
- Quitting while recording finishes the active writers before the app exits.

### Key files

| Path | What it is |
|---|---|
| `tools/record-it/Sources/RecordItApp/RecordItApplication.swift` | SwiftUI app and controls |
| `tools/record-it/Sources/RecordItApp/CameraPreview.swift` | Live camera framing preview + session lifecycle |
| `tools/record-it/Sources/RecordItApp/ScreenCaptureHealth.swift` | Screen watchdog + persistent recording diagnostics |
| `tools/record-it/Sources/RecordItApp/RecordingTelemetry.swift` | Live writer progress and recording-health model |
| `tools/record-it/Sources/RecordItApp/ScreenRecorder.swift` | ScreenCaptureKit pipeline |
| `tools/record-it/Sources/RecordItApp/CameraRecorder.swift` | AVFoundation camera + microphone pipeline |
| `tools/record-it/Sources/RecordItApp/EncoderSettings.swift` | Hardware encoder discovery + rate-control configuration |
| `tools/record-it/Sources/RecordItApp/MovieWriter.swift` | Hardware H.264/HEVC + AAC `.mov` writer |
| `tools/record-it/build-app.sh` | Builds, stages, and signs the app bundle |
| `tools/record-it/restart.sh` | Stops, rebuilds, and launches the debug app |

---

## phonebooth specifics

AppKit app that mirrors every USB-connected iPhone or iPad in its own window and
controls it through WebDriverAgent (WDA).

### Dev workflow

```bash
swift test --package-path tools/phonebooth
bash tools/phonebooth/restart.sh
tail -f ~/Library/Logs/"Phonebooth"/phonebooth.log
```

- `open -g "phonebooth://tap?x=0.5&y=0.5"` (also `swipe?dy=-300`,
  `type?text=hi`, `home`) drives the first phone without clicking. Use it for
  smoke tests.
- Each phone's xcodebuild output goes to
  `~/Library/Logs/Phonebooth/helper-<phone name>.log`. The line
  `ServerURLHere->...<-ServerURLHere` means WDA is up.

### Key behaviour

- Video: setting `kCMIOHardwarePropertyAllowScreenCaptureDevices` makes phones
  appear as `.external` muxed capture devices with model ID `iOS Device`. The same
  phone also appears as a Continuity Camera; the filter skips it.
- Control: `agent.sh` pins WebDriverAgent to a release, clones it into
  `~/Library/Application Support/Phonebooth/WebDriverAgent`, and rewrites the
  runner bundle ID to `com.mikecann.phonebooth.WebDriverAgentRunner`. The stock
  `com.facebook...` ID belongs to another team and can't be signed.
- The team ID comes from `PHONEBOOTH_TEAM_ID`, then `team-id` in the support
  folder, then the OU of the keychain's Apple Development certificate.
- `AgentRunner` runs `agent.sh run`, builds once per launch when the run fails
  with a signing or provisioning error (new phone, expired signing), and
  restarts the helper whenever a command fails.
- The app reaches WDA at `http://[tunnelIPAddress]:8100`, the USB tunnel address
  from `xcrun devicectl list devices`. No usbmux forwarding is needed.
- Touches go through `POST /phonebooth/touch`, a route in
  `tools/phonebooth/wda/PBFastInputCommands.m`. `agent.sh` copies it into
  WDA's `Commands/` folder and `#include`s it from `FBCustomCommands.m`, so the
  Xcode project isn't edited. WDA registers any `FBCommandHandler` class
  automatically. Do not move taps back to `/wda/tap`, `/wda/touchAndHold` or
  `/actions`: they snapshot the app's accessibility tree around every gesture,
  and a single tap took over 3 seconds on an iPhone XS Max.
- `agent.sh build` writes the route file's SHA to
  `DerivedData/phonebooth-routes.sha`. `agent.sh run` exits 3 when it doesn't
  match, which makes `AgentRunner` rebuild. Edit the `.m` file and the next
  launch rebuilds the helper by itself.
- `GET /phonebooth/orientation` returns the raw UIInterfaceOrientation.
  WDA's `/orientation` reports both landscapes as `LANDSCAPE`, which isn't
  enough to place touches. It snapshots the app, so it's only called on connect
  and rotation.
- `POST /phonebooth/nudge` presses and releases Shift. `AgentRunner` sends it
  every 20 seconds while the phone is unlocked (`KeepAwake`), which stops
  auto-lock. Tested on an iPhone XS Max with 30-second Auto-Lock: it stayed
  unlocked through 93 idle seconds, with nothing typed or opened. Never nudge a
  locked phone: it would wake the lock screen.
- The session (used for typing and `window/size`) is created with
  `shouldWaitForQuiescence: false` and `waitForIdleTimeout: 0`.
- A Bluetooth HID approach was tried and dropped. macOS 26 never got a classic
  Bluetooth link to the phone from a third-party app, and the iPhone only accepts
  a mouse through AssistiveTouch.

### Key files

| Path | What it is |
|---|---|
| `tools/phonebooth/Sources/PhoneboothApp/PhoneScreenDevices.swift` | Screen capture opt-in and phone discovery |
| `tools/phonebooth/Sources/PhoneboothApp/MirrorWindowController.swift` | Per-phone window, input handling |
| `tools/phonebooth/Sources/PhoneboothApp/PhoneGestures.swift` | Click/drag/scroll/key to gesture translation (pure) |
| `tools/phonebooth/Sources/PhoneboothApp/PhoneAgent.swift` | WDA HTTP client with an ordered command queue |
| `tools/phonebooth/Sources/PhoneboothApp/AgentRunner.swift` | Builds, starts and restarts WDA per phone |
| `tools/phonebooth/agent.sh` | Fetches, patches, signs, builds and runs WDA |
| `tools/phonebooth/wda/PBFastInputCommands.m` | Fast touch and orientation routes compiled into WDA |

---

## telemprompit specifics

SwiftUI/AppKit teleprompter for the Elgato Prompter. Paste notes, step
through them line by line, or auto-scroll.

### Dev workflow

```bash
swift test --package-path tools/telemprompit
bash tools/telemprompit/restart.sh
```

- `open -g telemprompit://next` (and `previous`, `play`, `pause`, `paste`,
  `settings`) drives the running app without focusing it. Use it for smoke
  tests instead of synthesising clicks.
- Global hotkeys use Carbon `RegisterEventHotKey`. Synthetic `CGEvent`s do
  not trigger them, so verify them with a real key press or clicker.
- `tools/lib/PrompterKit` is shared with Taskbar, Video HQ and Telemprompit.
  After changing it, run every consumer's tests:
  `swift test --package-path tools/lib/PrompterKit`,
  `swift test --package-path tools/taskbar`,
  `swift test --package-path tools/video-hq`,
  `swift test --package-path tools/telemprompit`.

---

## mikey-mouse specifics

Menu-bar replacement for Mac Mouse Fix. Side buttons become back/forward
navigation swipes in apps that ignore buttons 4 and 5, and the notched wheel
scrolls smoothly.

### Dev workflow

```bash
swift test --package-path tools/mikey-mouse
bash tools/mikey-mouse/restart.sh
tail -f ~/Library/Logs/mikey-mouse.log
```

- Always test the staged `~/Applications/Mikey Mouse.app` via `restart.sh`.
  Accessibility permission is keyed to the signed bundle.
- Verify side buttons with a real press over Finder. Each press logs the app
  under the pointer and whether it became a swipe. A swipe posted straight to
  Finder's pid with `CGEvent.postToPid` does not navigate, so it is no substitute.
- The event tap sits at the HID level on its own thread. Anything slow in the
  callback makes the whole mouse lag, and macOS turns a slow tap off.
- Only apps in `BackForwardRouter.swipeApps` get swipes. Chrome, VS Code and
  other apps that handle buttons 4 and 5 themselves must keep the raw click.
- Scroll feel (pixels per notch, time constant, acceleration) is subjective.
  Change it with Mike trying the real wheel, not from unit tests alone.

---

## website specifics

The mikerosoft.app site in `website/` deploys from `main` through
`.github/workflows/deploy-website.yml` whenever `website/` or `tools/` changes.

- Tool cards come from `website/src/tools.ts`. Give every tool a
  `tools/<name>/docs/header.webp` (1376x768, subject in the middle band because
  the card crops it to a 180px strip) and reference it as `header`.
- The added and updated dates on each card come from git history.
  `npm run dates` (run automatically before `dev` and `build`) writes the
  ignored `website/src/toolDates.generated.ts`. Added dates follow renames, so
  tools that moved from the repo root keep their first commit. Updated dates
  ignore `docs/` and the tool's `README.md`, since those describe a tool
  rather than change it.
- CI checks out with `fetch-depth: 0`. The generator refuses a shallow clone
  because every tool would get the same date.
- Every tool has its own page at `/tools/<name>` (`website/src/ToolPage.tsx`).
  It leads with real media: `video` first, then `screenshots`, and only falls
  back to the generated `header` art when there's nothing real. Give every tool
  real screenshots or a short clip of it working.
- Setup on the page is one step: copy a prompt that tells your agent to copy the
  source and make it your own. Don't add setup instructions to the page.
- The page copy (a tagline and a short intro, in Mike's voice with no em dashes)
  lives in `website/src/toolDetails.ts`. A new tool needs an entry there or
  `npm test` fails.
- "What's changed" on each page comes from git. `npm run changelog` (run
  automatically before `dev` and `build`) writes the ignored
  `website/public/changelog/<tool>.json` from commit subjects and bodies, so
  write commit bodies that say why something changed.
- `npm run build` also writes `dist/tools/<name>.html` with that tool's title,
  description and share image, so links shared on social previews properly.
- `npm test` in `website/` runs the tool list, sorting, git-history and tool
  page tests.

---

## scale-monitor specifics

- Monitor: HG584T05, "Display 4", AMD Radeon Graphics
- Registry key: `HKCU:\Control Panel\Desktop\PerMonitorSettings\RTK8405_0C_07E9_97^C9A428C8B2686559443005CCA2CE3E2E`
- `DpiValue = 4` → 200% scaling (normal use)
- `DpiValue = 7` → 300% scaling (filming)
- The script modifies the registry then broadcasts `WM_SETTINGCHANGE` +
  calls `ChangeDisplaySettingsEx("\\.\DISPLAY4", CDS_RESET)` to apply live

---

## PowerShell tips for this repo

```powershell
# Run a ps1 directly for testing
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\scale-monitor\scale-monitor.ps1

# Run a tool via its vbs launcher (same as taskbar click)
wscript.exe ".\tools\scale-monitor\scale-monitor.vbs"

# Re-run install after adding a tool
powershell -ExecutionPolicy Bypass -File .\install.ps1

# Check what's in c:\dev\tools (should only be stubs + exes)
Get-ChildItem C:\dev\tools\*.bat | Select-Object Name, Length
```
