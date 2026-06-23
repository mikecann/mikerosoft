![header](docs/header.webp)

# img-to-svg

Convert a raster image (PNG, JPEG, WebP, etc.) to SVG vector format.

Supports two engines:

- **vtracer** (default) — fast local vectorizer, works on any image. Three presets: `poster` (logos/icons/flat colour), `photo` (photographs/gradients), `bw` (black & white line art).
- **starvector-1b / starvector-8b** — AI model, best for icons, logos, and diagrams. Requires an NVIDIA GPU (~3 GB / ~16 GB VRAM respectively).

## Usage

```
img-to-svg logo.png
img-to-svg photo.webp --preset photo
img-to-svg icon.png --engine starvector-8b
img-to-svg icon.png out.svg --engine starvector-1b --max-length 2000
```

## Options

| Flag | Default | Description |
|---|---|---|
| `--engine` | `vtracer` | `vtracer`, `starvector-1b`, or `starvector-8b` |
| `--preset` | `poster` | vtracer preset: `poster`, `photo`, or `bw` |
| `--max-length` | `4000` | Max SVG token length (starvector only) |

## Dependencies

Run `deps.ps1` to install:

- **vtracer engine**: `pip install vtracer Pillow`
- **starvector engines**: PyTorch + CUDA, the `starvector` package, and an NVIDIA GPU
