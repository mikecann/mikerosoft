![header](docs/header.png)

# ![](icons/picture.png) img-upscale

Upscale an image locally with a quality-first transformer backend.

By default it uses progressive `2x` `Swin2SR` steps instead of trying to do one
huge jump in a single pass. That keeps the behavior simple:

- `2x` = one `2x` step
- `4x` = two `2x` steps
- `8x` = three `2x` steps
- `16x` = four `2x` steps

It opens in a small CMD window, asks whether you want `2x`, `4x`, `8x`, or `16x`,
then writes the result next to the original image with the chosen scale appended
to the file name.

## Usage

**From the terminal:**
```powershell
img-upscale <image_file>
img-upscale <image_file> --scale 2
img-upscale <image_file> --scale 8
img-upscale <image_file> --backend fast
```

**From File Explorer:**
Right-click any image file, then choose **Mike's Tools > Upscale Image**.
(On Windows 11, click "Show more options" first to get the classic menu.)

## Dependencies

The default quality backend needs Python packages:

- `torch`
- `transformers`
- `huggingface-hub`
- `safetensors`
- `numpy`
- `Pillow`

Run `deps.ps1` to check and install the easy bits.

On first run, the quality backend downloads the `caidas/swin2SR-lightweight-x2-64`
model from Hugging Face.

There is also an optional fast backend:

- `img-upscale <image> --backend fast`

That uses `realesrgan-ncnn-vulkan.exe` from `C:\dev\tools` if you already have it.

## Notes

- Default backend: progressive `caidas/swin2SR-lightweight-x2-64`
- Optional fast backend: `realesrgan-x4plus`
- Default scale is `2x`
- Supported scales: `2x`, `4x`, `8x`, `16x`
- Output format is inferred from the output filename, so the default behavior preserves the original extension.
- If `photo_x4.png` already exists, the tool writes `photo_x4_2.png` instead of overwriting it.
