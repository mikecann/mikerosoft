![header](docs/header.png)

# voice-type

Push-to-talk voice transcription that types directly into any focused window.
Runs entirely locally, no cloud, no subscription.

- **Windows**: hold **Right Ctrl**, speak, release to paste
- **macOS**: hold **Right Option**, speak, release to paste
- **Apple Silicon macOS**: uses **MLX Whisper** for the final transcription path when available for much better performance than the old CPU-only path

[![voice type](https://thumbs.video-to-markdown.com/dd2eac67.jpg)](https://youtu.be/lYjgJ8KIh-Y)

---


## Screenshots

![voice-type screenshot](docs/ss1.png)


## Quick start

### Prerequisites

- **Windows**: Python on `PATH`
- **macOS**: Apple Silicon recommended if you want the MLX speedup
- **macOS**: Homebrew installed
- **Both**: internet access on first run so models can download from Hugging Face

### Windows

```powershell
# First time: install dependencies
powershell -ExecutionPolicy Bypass -File .\tools\voice-type\deps.ps1

# Add to taskbar / Start menu
powershell -ExecutionPolicy Bypass -File .\install.ps1

# Or launch manually for testing
wscript.exe "C:\dev\me\mikerosoft.app\tools\voice-type\voice-type.vbs"
```

Right-click `C:\dev\tools\Voice Type.lnk` → **Pin to taskbar** for one-click launch.

### macOS

Known-good path:

- Apple Silicon Mac
- Homebrew Python
- run `setup_mac.sh`
- grant permissions when macOS asks
- launch with `voice-type-mac.sh`

```bash
# First time: create a venv and install dependencies
bash tools/voice-type/setup_mac.sh

# Launch or restart the background worker
bash tools/voice-type/voice-type-mac.sh

# Open settings
bash tools/voice-type/open-settings-mac.sh
```

On macOS, Spotlight can also open the settings app by typing `Voice Type`.

### Permissions on macOS

`voice-type` needs a few macOS permissions to work properly:

1. `Accessibility`
   Required so it can detect the global hotkey and inject text into other apps.
2. `Microphone`
   Required so it can record your speech.

If the hotkey does nothing, or transcription works but text does not paste, check:

- `System Settings` -> `Privacy & Security` -> `Accessibility`
- `System Settings` -> `Privacy & Security` -> `Microphone`

Grant access to the app that is actually running `voice-type`, usually your terminal
or the Python host it launched under.

---

## Usage

| Action | What happens |
| --- | --- |
| Hold the hotkey | Recording starts and an animated overlay appears at the bottom-centre of your monitor |
| Keep holding | Waveform bars respond to your voice and partial transcription builds up below them |
| Release the hotkey | Final transcription runs and text is pasted into the active window |
| Open settings | On Windows use the tray icon, on macOS use Spotlight `Voice Type` or `open-settings-mac.sh` |

The text is injected into whatever window had focus when you released the key —
text editors, browsers, chat apps, terminals, etc. Your clipboard is left untouched.

Hotkey by platform:

- **Windows**: Right Ctrl
- **macOS**: Right Option

---

## Overlay

While recording a pill-shaped overlay appears at the **bottom-centre of the
monitor containing the focused window**:

```
┌─┬──────────────────────────────────────┐
│ │  ● REC  ▂▄█▇▄▆▂                    │
│ │  "partial transcript text..."       │
└─┴──────────────────────────────────────┘
```

| Element                      | Description                                           |
| ---------------------------- | ----------------------------------------------------- |
| Coloured accent strip (left) | Red = recording, amber = transcribing                 |
| `● REC` / `...` label        | Current state                                         |
| Waveform bars                | 7 bars that animate to your mic level in real time    |
| Partial text                 | Streaming preview — updates ~every 0.5 s as you speak |

The overlay is configured so it **never steals keyboard focus**.

---

## Settings UI

### Windows

A microphone icon sits in the system tray. Its colour reflects the current state:

| Colour    | State                  |
| --------- | ---------------------- |
| Dark grey | Idle — ready to record |
| Red       | Recording              |
| Amber     | Transcribing           |
| Very dark | Disabled               |

**Right-click menu:**

| Item                  | Description                                                        |
| --------------------- | ------------------------------------------------------------------ |
| **Enabled** ✓         | Toggle the tool on/off without killing the process                 |
| **Formatter Enabled** | Turn local transcript cleanup on/off near the top of the menu      |
| **Open Log**          | Opens `voice-type.log` in Notepad                                  |
| **Run on Startup**    | Add/remove from `HKCU\...\Run` (auto-start with Windows)           |
| **Formatter → Model** | Choose the local cleanup model, only shown when formatter is enabled |
| **Formatter → Edit System Prompt...** | Open a multiline editor for the formatter system prompt |
| **Formatter → Reset System Prompt** | Restore the built-in default formatter prompt            |
| **Exit**              | Quit cleanly                                                       |

### macOS

macOS does not currently use the Windows tray flow.

- Open settings via Spotlight by typing `Voice Type`
- Or run `bash tools/voice-type/open-settings-mac.sh`
- The worker itself runs in the background via `voice-type-mac.sh`
- `Run on Startup` writes a LaunchAgent so it starts on next login

## How it works

- **Hotkey handling** — Windows polls `GetAsyncKeyState(VK_RCONTROL)` at 100 Hz.
  macOS uses a native event tap for Right Option and suppresses its normal accent-picker
  behaviour while the tool is active.
- **Audio capture** — `sounddevice` streams 16 kHz mono float32 from the
  default microphone into a NumPy buffer.
- **Streaming preview** — while the key is held, a background thread uses
  `tiny.en` to transcribe accumulated audio every 0.5 s and updates the
  overlay. This model is loaded as a separate instance so it never blocks
  the final transcription.
- **Final transcription** — on key release, the final model transcribes the
  full audio for accuracy. On Windows this is `faster-whisper` on CPU or CUDA.
  On Apple Silicon macOS, `voice-type` now prefers **MLX Whisper** for supported
  final models, which makes the final pass much faster than the previous CPU-only
  macOS path.
- **Text injection** — Windows injects text via `SendInput` with
  `KEYEVENTF_UNICODE`. macOS re-activates the target app and pastes with a
  clipboard-preserving `pbcopy` + `Cmd+V` flow.
- **Optional transcript cleanup** — for `final_only`, `hybrid`, and
  `precompute`, an optional local GGUF instruct model can lightly clean the
  final transcript before it is typed. Guardrails reject outputs that remove
  numbers, acronyms, URLs, or too much of the original wording, and the tool
  falls back to the raw transcript on validator failures, backend errors, or
  timeout. `stabilized` skips this step on purpose because it types partial
  segments before the full sentence exists.
- **Two-model design** — `tiny.en` (~75 MB, ~0.1 s/pass) for live preview;
  `small.en` (~244 MB, ~0.5–1.5 s) for final. No lock contention, so the
  streaming never delays the paste.
- **Monitor detection** — each platform finds the monitor containing the
  focused window, then centres the overlay at its bottom edge.
- **Waveform animation** — the overlay canvas polls `Recorder.get_rms()` at
  30 fps, driving 7 bottom-anchored bars with a smoothed exponential moving
  average. A sine-sweep animation plays during transcription.
- **Log rotation** — on startup, if `voice-type.log` exceeds 1 MB the file
  is trimmed to the last 200 lines automatically.

---

## Performance

| Hardware | Final backend | Final model | Typical post-release delay |
| --- | --- | --- | --- |
| CPU (any) | `faster-whisper` | `small.en` | ~0.5–1.5 s depending on clip length |
| NVIDIA GPU (CUDA) | `faster-whisper` | `large-v3-turbo` | ~0.2 s |
| Apple Silicon | `mlx-whisper` | `small.en` / `large-v3-turbo` | much faster than the old CPU-only macOS path, with `large-v3-turbo` now feeling comfortably usable |

Windows auto-detects CUDA (`ctranslate2.get_cuda_device_count()` +
`cublas64_12.dll` load check) and falls back to CPU automatically.

On Apple Silicon, `voice-type` prefers MLX for supported **final** models and
falls back safely if MLX is unavailable. The streaming preview path remains a
separate `faster-whisper` model for now.

On Intel Macs, expect the fallback path rather than the MLX speedup.

Models download once from HuggingFace on first use and are cached locally.

### Formatter benchmark

I benchmarked the local cleanup models on real transcript samples on this
machine after the model was warm:

| Formatter model | Typical added latency | What happened |
| --------------- | --------------------- | ------------- |
| `Qwen2.5 0.5B`  | ~0.9–1.7 s            | Best latency/guardrail balance, now the default |
| `Qwen2.5 1.5B`  | ~1.6–3.8 s            | Cleaner punctuation, but too eager to rewrite wording |
| `SmolLM2 1.7B`  | ~2.1–3.9 s            | Usually left the text unchanged |

That is why the formatter is **off by default**, and why the default model is
the smaller `Qwen2.5 0.5B` rather than the stronger 1.5B model.

---

## Configuration

Use the Windows tray menu or the macOS settings window for normal configuration.
The persisted settings live in `settings.json` beside the script.

Useful keys:

| Setting              | Default          | Description |
| -------------------- | ---------------- | ----------- |
| `final_model`        | `"small.en"` / `"large-v3-turbo"` | Final transcription model. On Apple Silicon, supported values can use MLX |
| `stream_model`       | `"tiny.en"`      | Preview model |
| `output_mode`        | `"final_only"`   | Finalise strategy |
| `formatter_enabled`  | `false`          | Turn local transcript cleanup on/off |
| `formatter_model`    | `"qwen2.5-0.5b"` | Local cleanup model preset |
| `corrections`        | `{...}`          | Exact phrase replacements applied after transcription |

If you want to tweak hardcoded behaviour, edit the constants near the top of
`voice-type.py`:

| Constant | Default | Description |
| --- | --- | --- |
| `HOTKEY_VK` | `0xA3` | Windows virtual key for push-to-talk (Right Ctrl) |
| `CPU_MODEL` | `"small.en"` | Final transcription model on CPU |
| `GPU_MODEL` | `"large-v3-turbo"` | Final transcription model on CUDA |
| `STREAM_MODEL` | `"tiny.en"` | Preview model (separate instance) |
| `STREAM_INTERVAL` | `0.5` | Seconds between streaming preview passes |
| `DEVICE` | `None` | Mic device (`None` = system default) |

**Common hotkey alternatives:**

| VK code | Key         |
| ------- | ----------- |
| `0xA5`  | Right Alt   |
| `0x14`  | Caps Lock   |
| `0x91`  | Scroll Lock |
| `0x7B`  | F12         |

---

## Dependencies

### Windows

Installed automatically by `deps.ps1`:

```
faster-whisper   speech-to-text engine (CTranslate2 backend)
sounddevice      microphone capture
numpy            audio buffer maths
Pillow           tray icon drawing
pystray          system tray integration
huggingface_hub  GGUF model downloads
llama-cpp-python local GGUF inference for transcript cleanup
```

### macOS

Installed automatically by `setup_mac.sh`:

```
mlx-whisper      Apple Silicon Whisper backend for fast final transcription
faster-whisper   speech-to-text engine for preview and fallback transcription
sounddevice      microphone capture
numpy            audio buffer maths
Pillow           overlay drawing
huggingface_hub  model downloads
llama-cpp-python local GGUF inference for transcript cleanup
pyobjc-framework-Cocoa native macOS integration
```

## Files

| File                  | Purpose                                                  |
| --------------------- | -------------------------------------------------------- |
| `voice-type.py`       | Main script — audio, tray UI, transcription, injection   |
| `speech_backends.py`  | Backend selection and the MLX Whisper adapter            |
| `text_formatter.py`   | Local LLM formatting guardrails and GGUF backend         |
| `benchmark_formatter.py` | Quick local benchmark for formatter model experiments |
| `tests/test_text_formatter.py` | Unit tests for formatter validation and fallback |
| `tests/test_speech_backends.py` | Unit tests for backend selection logic          |
| `voice-type.vbs`      | Silent launcher (no console window)                      |
| `voice-type.ps1`      | PowerShell launcher called by the VBS                    |
| `deps.ps1`            | Installs Python dependencies                             |
| `setup_mac.sh`        | Creates the macOS venv and installs Python dependencies  |
| `voice-type-mac.sh`   | macOS restart script                                     |
| `open-settings-mac.sh`| Opens the macOS settings window                          |
| `voice-type.log`      | Runtime log (gitignored, auto-rotates at 1 MB)           |