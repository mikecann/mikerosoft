# unmultitrack

Right-click a multi-track OBS/Aitum video and extract each video stream into its own normal video file.

By default, every audio stream is copied into each extracted output, which is usually what you want when importing the files into Premiere, Resolve, or another editor.

## Usage

```powershell
unmultitrack "C:\videos\recording.mp4"
```

For `recording.mp4`, output goes into:

```text
recording_unmultitracked\
  recording_v1.mp4
  recording_v2.mp4
```

Existing files are not overwritten. If `recording_v1.mp4` already exists, the next output becomes `recording_v1_2.mp4`.

## Options

```powershell
unmultitrack recording.mp4 --video-only
unmultitrack recording.mp4 --overwrite
unmultitrack recording.mp4 --dry-run
```

`--video-only` extracts only video streams. Without it, all audio streams are copied into each output.

`--allow-single` copies a file with only one video stream. The default is to stop, because that usually means you right-clicked the wrong file.

## Explorer

Run the root installer:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Then right-click a video file and choose:

```text
Mike's Tools > Un-multi-track Video
```

## Requirements

- `ffmpeg.exe` in `C:\dev\tools`, or `ffmpeg` on PATH
- Optional: `ffprobe.exe` in `C:\dev\tools`, or `ffprobe` on PATH

If `ffprobe` is missing, the tool falls back to parsing `ffmpeg -i` stream output.
