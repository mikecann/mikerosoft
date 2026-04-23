![header](docs/header.png)

# ![](icons/film.png) transcribe

Transcribes a video file to text using [faster-whisper-xxl](https://github.com/Purfview/whisper-standalone-win). Extracts audio with ffmpeg, runs Whisper, and saves the transcript as an `.srt` file next to the input.

## Usage

**From the terminal:**
```
transcribe <video_file> [--cpu]
```

**From File Explorer:**
Right-click any video file, then choose **Mike's Tools > Transcribe Video**.
(On Windows 11, click "Show more options" first to get the classic menu.)
`install.ps1` registers this for `.mp4`, `.mkv`, `.avi`, `.mov`, `.wmv`, `.webm`, and other common video formats.

| Argument | Description |
|---|---|
| `<video_file>` | Path to the video (or audio) file to transcribe |
| `--cpu` | Force CPU inference (default is CUDA; falls back to CPU automatically if CUDA fails) |

The transcript is saved as `<input_basename>.srt` in the same folder as the input file.

## Screenshots

![screenshot](docs/ss1.png)

## macOS / Linux (POSIX)

Use the **`transcribe`** launcher in this folder (also linked by `install_mac.sh` into `~/.local/bin`).

1. Install deps once:

```bash
bash tools/transcribe/deps.sh
```

2. Run:

```bash
transcribe /path/to/video.mp4 [--cpu] [--model small]
```

Uses **`ffmpeg` on PATH** and the **`faster-whisper`** Python package. Default model is **`small`**; override with **`TRANSCRIBE_MODEL`** or **`--model`**.

**Model quality (Mac / pip):** `base` and `small` download quickly and are fine for drafts. For closer parity with large Windows runs, use **`TRANSCRIBE_MODEL=large-v3`** or **`--model large-v3`** (much larger download and slower on CPU).

Windows continues to use **`transcribe.bat`** + **`faster-whisper-xxl.exe`** in `C:\dev\tools`.

## Dependencies (Windows)

Large binaries that must be downloaded manually and placed in `C:\dev\tools`:

| File | Download |
|---|---|
| `ffmpeg.exe` | https://ffmpeg.org/download.html |
| `faster-whisper-xxl.exe` | https://github.com/Purfview/whisper-standalone-win/releases |
| `_models\` | Whisper model files (downloaded by faster-whisper-xxl on first run) |

Run `deps.ps1` (or `install.ps1`) to check whether these are in place.

## Notes

- Uses `float16` compute type when running on CUDA.
- Audio is extracted to a temp `.wav` file and cleaned up after transcription.
