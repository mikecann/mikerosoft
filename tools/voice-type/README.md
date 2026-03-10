![header](docs/header.png)

# voice-type

Push-to-talk voice transcription that types directly into any focused window.
Hold **Right Ctrl** while speaking, release to paste. Runs entirely locally —
no cloud, no subscription.

[![voice type](https://thumbs.video-to-markdown.com/dd2eac67.jpg)](https://youtu.be/lYjgJ8KIh-Y)

---


## Screenshots

![voice-type screenshot](docs/ss1.png)


## Quick start

```powershell
# First time: install dependencies
powershell -ExecutionPolicy Bypass -File .\tools\voice-type\deps.ps1

# Add to taskbar (run install.ps1 from repo root if not already done)
powershell -ExecutionPolicy Bypass -File .\install.ps1

# Or launch manually for testing
wscript.exe "C:\dev\me\mikerosoft.app\tools\voice-type\voice-type.vbs"
```

Right-click `C:\dev\tools\Voice Type.lnk` → **Pin to taskbar** for one-click launch.

---

## Usage

| Action                    | What happens                                                                     |
| ------------------------- | -------------------------------------------------------------------------------- |
| Hold **Right Ctrl**       | Recording starts — animated overlay appears at the bottom-centre of your monitor |
| Keep holding              | Waveform bars respond to your voice; partial transcription builds up below them  |
| Release **Right Ctrl**    | Final transcription runs and text is pasted into the active window               |
| Right-click **tray icon** | Settings menu (see below)                                                        |

The text is injected into whatever window had focus when you released the key —
text editors, browsers, chat apps, terminals, etc. Your clipboard is left untouched.

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

The overlay uses `WS_EX_NOACTIVATE` so it **never steals keyboard focus**.

---

## System tray icon

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

---

## How it works

- **Hotkey polling** — `GetAsyncKeyState(VK_RCONTROL)` at 100 Hz. No global
  keyboard hook is installed, so `Ctrl+C`, `Ctrl+V`, etc. are never affected.
- **Audio capture** — `sounddevice` streams 16 kHz mono float32 from the
  default microphone into a NumPy buffer.
- **Streaming preview** — while the key is held, a background thread uses
  `tiny.en` to transcribe accumulated audio every 0.5 s and updates the
  overlay. This model is loaded as a separate instance so it never blocks
  the final transcription.
- **Final transcription** — on key release, `small.en` (or `large-v3-turbo`
  on CUDA) transcribes all recorded audio for accuracy. Result is injected
  directly into the focused window via `SendInput` with `KEYEVENTF_UNICODE`
  flags — the clipboard is never touched.
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
- **Monitor detection** — `MonitorFromWindow` + `GetMonitorInfoW` find the
  work area of the monitor containing the focused window. The overlay is
  centred at its bottom edge.
- **Waveform animation** — the overlay canvas polls `Recorder.get_rms()` at
  30 fps, driving 7 bottom-anchored bars with a smoothed exponential moving
  average. A sine-sweep animation plays during transcription.
- **Log rotation** — on startup, if `voice-type.log` exceeds 1 MB the file
  is trimmed to the last 200 lines automatically.

---

## Performance

| Hardware          | Final model      | Typical post-release delay          |
| ----------------- | ---------------- | ----------------------------------- |
| CPU (any)         | `small.en`       | ~0.5–1.5 s depending on clip length |
| NVIDIA GPU (CUDA) | `large-v3-turbo` | ~0.2 s                              |

CUDA is auto-detected at startup (`ctranslate2.get_cuda_device_count()` +
`cublas64_12.dll` load check). Falls back to CPU automatically.

Both models download once from HuggingFace on first use and are cached in
`%USERPROFILE%\.cache\huggingface\`.

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

Use the tray menu for normal configuration. The persisted settings live in
`settings.json` beside the script.

Useful keys:

| Setting              | Default          | Description |
| -------------------- | ---------------- | ----------- |
| `final_model`        | `"small.en"` / `"large-v3-turbo"` | Final transcription model |
| `stream_model`       | `"tiny.en"`      | Preview model |
| `output_mode`        | `"final_only"`   | Finalise strategy |
| `formatter_enabled`  | `false`          | Turn local transcript cleanup on/off |
| `formatter_model`    | `"qwen2.5-0.5b"` | Local cleanup model preset |
| `corrections`        | `{...}`          | Exact phrase replacements applied after transcription |

If you want to tweak hardcoded behaviour, edit the constants near the top of
`voice-type.py`:

| Constant          | Default            | Description                                   |
| ----------------- | ------------------ | --------------------------------------------- |
| `HOTKEY_VK`       | `0xA3`             | Virtual key for push-to-talk (Right Ctrl)     |
| `CPU_MODEL`       | `"small.en"`       | Final transcription model on CPU              |
| `GPU_MODEL`       | `"large-v3-turbo"` | Final transcription model on CUDA             |
| `STREAM_MODEL`    | `"tiny.en"`        | Preview model (always CPU, separate instance) |
| `STREAM_INTERVAL` | `0.5`              | Seconds between streaming preview passes      |
| `DEVICE`          | `None`             | Mic device (`None` = system default)          |

**Common hotkey alternatives:**

| VK code | Key         |
| ------- | ----------- |
| `0xA5`  | Right Alt   |
| `0x14`  | Caps Lock   |
| `0x91`  | Scroll Lock |
| `0x7B`  | F12         |

---

## Dependencies

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

---

## Files

| File                  | Purpose                                                  |
| --------------------- | -------------------------------------------------------- |
| `voice-type.py`       | Main script — audio, tray UI, transcription, injection   |
| `text_formatter.py`   | Local LLM formatting guardrails and GGUF backend         |
| `benchmark_formatter.py` | Quick local benchmark for formatter model experiments |
| `tests/test_text_formatter.py` | Unit tests for formatter validation and fallback |
| `voice-type.vbs`      | Silent launcher (no console window)                      |
| `voice-type.ps1`      | PowerShell launcher called by the VBS                    |
| `deps.ps1`            | Installs Python dependencies                             |
| `voice-type.log`      | Runtime log (gitignored, auto-rotates at 1 MB)           |