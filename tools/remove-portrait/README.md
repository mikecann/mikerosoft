![header](docs/header.webp)

# ![](icons/film.png) remove-portrait

Removes the background from a talking-head video and writes a transparent
`.mov` that can be dropped over a screen recording in DaVinci Resolve.

The default backend is RobustVideoMatting (RVM), which is designed for human
video matting and uses CUDA through PyTorch. The older `rembg` backend is still
available as a fallback.

## Usage

**From the terminal:**

```powershell
remove-portrait C:\videos\clip.mkv
```

**From File Explorer:**
Right-click a video file, then choose **Mike's Tools > Remove Portrait Background**.

The default output is saved beside the input at the same frame size as the
source video:

```text
clip_portrait_removed.mov
```

## Tuning

For quick tests:

```powershell
remove-portrait C:\videos\clip.mkv --sample-seconds 3 --preview
remove-portrait C:\videos\clip.mkv --sample-seconds 3 --preview --max-width 960
```

Useful options:

```text
--backend rvm            default; faster video-native CUDA backend
--backend rembg          older frame-by-frame image segmentation backend
--codec prores           default; high-quality ProRes 4444 alpha
--codec qtrle            huge QuickTime Animation alpha output
--max-width 960          faster preview/output width; default is source size
--rvm-downsample-ratio 0.125
--rvm-chunk 4
--model u2net_human_seg  fastest useful default
--model isnet-general-use
--model birefnet-portrait
--shrink 1               shrink the matte edge by N pixels
--blur 1                 soften the matte edge
--alpha-matting          slower edge solver; useful for awkward clips
--preview                rembg backend only; also write a checkerboard MP4 preview
--no-audio               do not copy source audio into the MOV
```

## Notes

- Output uses ProRes 4444 with alpha because Resolve imports it reliably and it
  is much smaller than QuickTime Animation (`qtrle`). The default ProRes encode
  uses `-qscale:v 12 -alpha_bits 8`.
- RVM files live in `C:\dev\tools\_models\remove-portrait`, created by
  `deps.ps1`. Model/source files are kept out of the repo.
- The `rembg` backend can use `onnxruntime-gpu`; RVM uses PyTorch CUDA.
- The source video has no alpha channel, so the output must be encoded into a
  new alpha-capable format. ProRes 4444 is the default because it is
  Resolve-friendly and far smaller than `qtrle`.
- Source-size 4K segmentation is slow on CPU. Use `--max-width 960` for tuning
  runs, then run without it for the final Resolve overlay.
- The `rembg` fallback may download model weights into `%USERPROFILE%\.u2net`.
- Full-frame output is intentional. Crop-to-subject was avoided because moving
  around the camera frame would make positioning harder in Resolve.

See [docs/spike-results.md](docs/spike-results.md) for the backend/codec tests
that led to the current defaults.
