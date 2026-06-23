![header](docs/header.webp)

# ![](icons/film.png) transcribe

Transcribes a video file to text using [faster-whisper-xxl](https://github.com/Purfview/whisper-standalone-win). Extracts audio with ffmpeg, runs Whisper, and saves the transcript as an `.srt` file next to the input.

## Usage

**From the terminal:**
```
transcribe <video_file> [--cpu] [--diarize]
```

**From File Explorer:**
Right-click any video file, then choose **Mike's Tools > Transcribe Video**.
For speaker labels, choose **Mike's Tools > Transcribe with Speakers**. This uses
`--diarize --model large-v3` because speaker-labelled transcripts are usually worth
the slower, higher-quality model.
(On Windows 11, click "Show more options" first to get the classic menu.)
`install.ps1` registers this for `.mp4`, `.mkv`, `.avi`, `.mov`, `.wmv`, `.webm`, and other common video formats.

| Argument | Description |
|---|---|
| `<video_file>` | Path to the video (or audio) file to transcribe |
| `--cpu` | Force CPU inference (default is CUDA; falls back to CPU automatically if CUDA fails) |
| `--diarize` | Add speaker labels such as `[SPEAKER_00]` using pyannote.audio |
| `--num-speakers <n>` | Tell diarization the exact number of speakers |
| `--min-speakers <n>` / `--max-speakers <n>` | Give diarization a speaker-count range |

The transcript is saved as `<input_basename>.srt` in the same folder as the input file.

## Speaker diarization

Use `--diarize` when you want speaker-labelled transcript lines:

```powershell
transcribe C:\videos\meeting.mp4 --diarize --min-speakers 2 --max-speakers 4
```

This labels speakers as `SPEAKER_00`, `SPEAKER_01`, etc. It does not know real names
like "Mike" unless a separate voice-identification step is added later.

`--diarize` uses [pyannote.audio](https://huggingface.co/pyannote) with the default
`pyannote/speaker-diarization-community-1` model. Before first use:

1. Install optional Python deps:

   ```powershell
   python -m pip install faster-whisper pyannote.audio
   ```

   On macOS / Linux you can also run:

   ```bash
   bash tools/transcribe/deps.sh --with-diarize
   ```

2. Request/accept access to the pyannote model on Hugging Face using the same account as your token.
3. Create a Hugging Face token at `https://hf.co/settings/tokens`.
4. Set `HF_TOKEN`, add `HF_TOKEN=...` to the repo-root `.env`, or pass `--hf-token <token>`.

On Windows, the normal path still uses `faster-whisper-xxl.exe`. Only `--diarize`
switches to the Python path because the standalone EXE does not output speaker
diarization. The Explorer **Transcribe with Speakers** command also passes
`--model large-v3`; from the terminal you can choose a faster model yourself:

```powershell
transcribe C:\videos\meeting.mp4 --diarize --model small
```

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
transcribe /path/to/video.mp4 [--cpu] [--model small] [--diarize]
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
