# Agent guidance - mikerosoft.app

Instructions for AI agents (Cursor, etc.) working in this repo.

---

## Repo purpose

A bunch of personalised tools for Windows users. Each tool lives in its own
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
├── .gitignore
└── tools\
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
    └── transcribe\
        ├── transcribe.bat         ← uses %EXEDIR% for ffmpeg / whisper paths
        └── deps.ps1               ← checks ffmpeg.exe + faster-whisper-xxl.exe exist
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
- **No .NET SDK required.** Built by `MSBuild.exe` from .NET Framework 4
  (`C:\Windows\Microsoft.NET\Framework64\v4.0.30319\MSBuild.exe`).
- Project file: `task-stats\task-stats.csproj` (targets .NET Framework 4, embeds `icons\*.png` as manifest resources).
- Compiled DLL is cached at `%LOCALAPPDATA%\task-stats\task-stats.dll`.
- `task-stats.ps1` is a thin launcher - it loads the DLL and calls `[TaskMon.App]::Run()`.
  No compilation at runtime, so startup is instant and no OOM risk in Cursor.

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
| `tools\task-stats\task-stats.csproj` | MSBuild project file |
| `tools\task-stats\Native.cs` | Win32 P/Invoke + NVML declarations |
| `tools\task-stats\Settings.cs` | JSON-backed settings |
| `tools\task-stats\Metrics.cs` | CircularBuffer + PerformanceCounter/NVML sampling |
| `tools\task-stats\OverlayForm.cs` | Layered window rendering + hit-test + menu |
| `tools\task-stats\SettingsForm.cs` | Tabbed settings dialog |
| `tools\task-stats\App.cs` | DarkRenderer + App entry point |
| `tools\task-stats\icons\` | famfamfam silk icons - CC BY 2.5, https://www.famfamfam.com/lab/icons/silk/ |
| `tools\task-stats\build.bat` | Builds via MSBuild.exe, kills old instance first |
| `tools\task-stats\build-and-run.bat` | Full dev cycle: kill + build + launch |
| `tools\task-stats\kill.bat` | Kills task-stats by matching `*task-stats.ps1*` in WMI |
| `%LOCALAPPDATA%\task-stats\task-stats.dll` | Compiled output (not in git) |
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
