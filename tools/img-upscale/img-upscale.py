"""
img-upscale - local image upscaling.

Default backend:
  progressive Swin2SR x2 steps

Fallback backend:
  Real-ESRGAN ncnn Vulkan (faster, but more artifact-prone)
"""
from __future__ import annotations

import argparse
import os
import pathlib
import subprocess
import sys


DEFAULT_SCALE = 2
VALID_SCALES = {2, 4, 8, 16}
DEFAULT_BACKEND = "quality"
VALID_BACKENDS = {"quality", "fast"}
UPSCALE_BINARY = "realesrgan-ncnn-vulkan.exe"
FAST_MODEL_NAME = "realesrgan-x4plus"
QUALITY_MODEL_ID = "caidas/swin2SR-lightweight-x2-64"
DEFAULT_TILE_SIZE = 256
DEFAULT_TILE_OVERLAP = 32


def normalize_scale_choice(raw_choice: str) -> int:
    choice = raw_choice.strip().lower()
    if not choice:
        return DEFAULT_SCALE
    if choice.startswith("x"):
        choice = choice[1:]
    if not choice.isdigit():
        raise ValueError(f"Unsupported scale: {raw_choice}")

    scale = int(choice)
    if scale not in VALID_SCALES:
        raise ValueError(f"Unsupported scale: {raw_choice}")
    return scale


def normalize_backend_name(raw_choice: str) -> str:
    choice = raw_choice.strip().lower()
    if not choice:
        return DEFAULT_BACKEND
    if choice not in VALID_BACKENDS:
        raise ValueError(f"Unsupported backend: {raw_choice}")
    return choice


def normalize_tile_size_choice(raw_choice: str) -> int | None:
    choice = raw_choice.strip().lower()
    if not choice or choice == "auto":
        return None
    if not choice.isdigit():
        raise ValueError(f"Unsupported tile size: {raw_choice}")

    tile_size = int(choice)
    if tile_size < 64 or tile_size % 8 != 0:
        raise ValueError(f"Unsupported tile size: {raw_choice}")
    return tile_size


def prompt_for_scale() -> int:
    while True:
        raw_choice = input("Upscale factor [2 or 4, default 2]: ")
        try:
            return normalize_scale_choice(raw_choice)
        except ValueError:
            print("Please enter 2, 4, x2, x4, or just press Enter for 2x.")


def build_default_output_path(*, input_path: pathlib.Path, scale: int) -> pathlib.Path:
    candidate = input_path.with_name(f"{input_path.stem}_x{scale}{input_path.suffix}")
    if not candidate.exists():
        return candidate

    index = 2
    while True:
        candidate = input_path.with_name(f"{input_path.stem}_x{scale}_{index}{input_path.suffix}")
        if not candidate.exists():
            return candidate
        index += 1


def resolve_exe_dir() -> pathlib.Path:
    env_exe_dir = os.environ.get("EXEDIR")
    if env_exe_dir:
        return pathlib.Path(env_exe_dir)
    return pathlib.Path(__file__).resolve().parent


def get_quality_model_id() -> str:
    return QUALITY_MODEL_ID


def build_quality_scale_plan(*, scale: int) -> list[int]:
    if scale not in VALID_SCALES:
        raise ValueError(f"Unsupported scale: {scale}")

    step_count = 0
    current_scale = scale
    while current_scale > 1:
        if current_scale % 2 != 0:
            raise ValueError(f"Unsupported scale: {scale}")
        current_scale //= 2
        step_count += 1

    return [2] * step_count


def build_tile_starts(*, length: int, tile_size: int, tile_overlap: int) -> list[int]:
    if length <= tile_size:
        return [0]

    step = tile_size - (tile_overlap * 2)
    if step <= 0:
        raise ValueError("Tile overlap must leave a positive tile step")

    last_start = max(0, length - tile_size)
    starts = list(range(0, last_start + 1, step))
    if starts[-1] != last_start:
        starts.append(last_start)
    return starts


def build_fast_upscale_command(
    *,
    exe_dir: pathlib.Path,
    input_path: pathlib.Path,
    output_path: pathlib.Path,
    scale: int,
) -> list[pathlib.Path | str]:
    return [
        exe_dir / UPSCALE_BINARY,
        "-i",
        input_path,
        "-o",
        output_path,
        "-n",
        FAST_MODEL_NAME,
        "-s",
        str(scale),
    ]


def print_missing_fast_dependency_help(*, exe_dir: pathlib.Path) -> None:
    print("Error: Real-ESRGAN fast backend is not installed.")
    print()
    print(f"Expected to find: {exe_dir / UPSCALE_BINARY}")
    print(f"Expected models in: {exe_dir / 'models'}")
    print()
    print("Install it by extracting the Windows Real-ESRGAN ncnn zip into C:\\dev\\tools")
    print("so that the exe sits at C:\\dev\\tools\\realesrgan-ncnn-vulkan.exe")
    print("and the model files sit under C:\\dev\\tools\\models\\.")


def print_missing_quality_dependency_help() -> None:
    print("Error: quality backend dependencies are missing.")
    print()
    print("Run:")
    print("  powershell -ExecutionPolicy Bypass -File tools\\img-upscale\\deps.ps1")
    print()
    print("This installs the Python packages for the Swin2SR quality backend.")


def get_resampling_lanczos():
    try:
        from PIL import Image
    except ImportError:
        print_missing_quality_dependency_help()
        raise

    if hasattr(Image, "Resampling"):
        return Image.Resampling.LANCZOS
    return Image.LANCZOS


def upscale_alpha_channel(*, alpha_channel, size: tuple[int, int]):
    return alpha_channel.resize(size, get_resampling_lanczos())


def load_input_image(*, input_path: pathlib.Path):
    try:
        from PIL import Image
    except ImportError:
        print_missing_quality_dependency_help()
        raise

    image = Image.open(input_path)
    if "A" not in image.getbands():
        return image.convert("RGB"), None

    alpha_channel = image.getchannel("A")
    return image.convert("RGB"), alpha_channel


def convert_reconstruction_to_image(*, reconstruction):
    import numpy as np
    from PIL import Image

    array = reconstruction.data.squeeze().float().cpu().clamp_(0, 1).numpy()
    array = (array * 255.0).round().astype(np.uint8)
    array = np.moveaxis(array, 0, 2)
    return Image.fromarray(array)


def run_quality_step(*, model, processor, device: str, input_image, torch_module):
    pixel_values = processor(input_image, return_tensors="pt").pixel_values.to(device)
    with torch_module.inference_mode():
        outputs = model(pixel_values)
    output_image = convert_reconstruction_to_image(reconstruction=outputs.reconstruction)
    del outputs
    del pixel_values
    if device == "cuda":
        torch_module.cuda.empty_cache()
    return output_image


def run_tiled_quality_step(
    *,
    model,
    processor,
    device: str,
    input_image,
    torch_module,
    tile_size: int,
    tile_overlap: int,
):
    from PIL import Image

    image_width, image_height = input_image.size
    if image_width <= tile_size and image_height <= tile_size:
        return run_quality_step(
            model=model,
            processor=processor,
            device=device,
            input_image=input_image,
            torch_module=torch_module,
        )

    x_starts = build_tile_starts(length=image_width, tile_size=tile_size, tile_overlap=tile_overlap)
    y_starts = build_tile_starts(length=image_height, tile_size=tile_size, tile_overlap=tile_overlap)
    total_tiles = len(x_starts) * len(y_starts)
    output_image = Image.new("RGB", (image_width * 2, image_height * 2))

    tile_index = 0
    for start_y in y_starts:
        core_height = min(tile_size, image_height - start_y)
        for start_x in x_starts:
            tile_index += 1
            core_width = min(tile_size, image_width - start_x)
            src_x0 = max(0, start_x - tile_overlap)
            src_y0 = max(0, start_y - tile_overlap)
            src_x1 = min(image_width, start_x + core_width + tile_overlap)
            src_y1 = min(image_height, start_y + core_height + tile_overlap)

            print(
                f"    Tile {tile_index}/{total_tiles}"
                f"  input=({src_x0},{src_y0})-({src_x1},{src_y1})"
            )

            tile_image = input_image.crop((src_x0, src_y0, src_x1, src_y1))
            upscaled_tile = run_quality_step(
                model=model,
                processor=processor,
                device=device,
                input_image=tile_image,
                torch_module=torch_module,
            )

            crop_x0 = (start_x - src_x0) * 2
            crop_y0 = (start_y - src_y0) * 2
            crop_x1 = crop_x0 + (core_width * 2)
            crop_y1 = crop_y0 + (core_height * 2)
            paste_tile = upscaled_tile.crop((crop_x0, crop_y0, crop_x1, crop_y1))
            output_image.paste(paste_tile, (start_x * 2, start_y * 2))

    return output_image


def resize_output_image(*, image, size: tuple[int, int]):
    return image.resize(size, get_resampling_lanczos())


def attach_alpha_if_needed(*, image, alpha_channel):
    if alpha_channel is None:
        return image

    alpha = upscale_alpha_channel(alpha_channel=alpha_channel, size=image.size)
    image.putalpha(alpha)
    return image


def save_output_image(*, image, output_path: pathlib.Path) -> None:
    output_suffix = output_path.suffix.lower()
    if output_suffix in {".jpg", ".jpeg"} and image.mode != "RGB":
        image = image.convert("RGB")

    save_kwargs = {}
    if output_suffix in {".jpg", ".jpeg"}:
        save_kwargs = {"quality": 95}

    image.save(output_path, **save_kwargs)


def run_fast_upscale(
    *,
    exe_dir: pathlib.Path,
    input_path: pathlib.Path,
    output_path: pathlib.Path,
    scale: int,
) -> int:
    binary_path = exe_dir / UPSCALE_BINARY
    if not binary_path.exists():
        print_missing_fast_dependency_help(exe_dir=exe_dir)
        return 1

    print("Upscaling image with Real-ESRGAN fast backend...")
    print(f"  Input:  {input_path}")
    print(f"  Output: {output_path}")
    print(f"  Scale:  x{scale}")
    print()

    command = build_fast_upscale_command(
        exe_dir=exe_dir,
        input_path=input_path,
        output_path=output_path,
        scale=scale,
    )
    result = subprocess.run(command, check=False)
    if result.returncode != 0:
        print()
        print(f"Error: upscaler failed with exit code {result.returncode}")
        return result.returncode

    if not output_path.exists():
        print()
        print("Error: upscaler reported success but no output file was created.")
        return 1

    print()
    print("Upscale complete!")
    print(f"Output saved to: {output_path}")
    return 0


def run_quality_upscale(
    *,
    input_path: pathlib.Path,
    output_path: pathlib.Path,
    scale: int,
    tile_size_override: int | None,
) -> int:
    try:
        import torch
        from transformers import Swin2SRForImageSuperResolution, Swin2SRImageProcessor
    except ImportError:
        print_missing_quality_dependency_help()
        return 1

    try:
        input_image, alpha_channel = load_input_image(input_path=input_path)
    except ImportError:
        return 1

    model_id = get_quality_model_id()
    scale_plan = build_quality_scale_plan(scale=scale)
    device = "cuda" if torch.cuda.is_available() else "cpu"
    tile_size = tile_size_override or DEFAULT_TILE_SIZE

    print("Upscaling image with progressive Swin2SR quality backend...")
    print(f"  Input:    {input_path}")
    print(f"  Output:   {output_path}")
    print(f"  Scale:    x{scale}")
    print(f"  Device:   {device}")
    print(f"  Model:    {model_id}")
    print(f"  Steps:    {' x '.join(['2'] * len(scale_plan))} -> x{scale}")
    print(f"  Tiling:   {tile_size}px tiles with {DEFAULT_TILE_OVERLAP}px overlap")
    print("  Note:     first run downloads the model from Hugging Face")
    print()

    processor = Swin2SRImageProcessor.from_pretrained(model_id)
    model = Swin2SRForImageSuperResolution.from_pretrained(model_id).to(device)
    current_image = input_image

    for step_index, step_scale in enumerate(scale_plan, start=1):
        print(f"  Running step {step_index}/{len(scale_plan)} at x{step_scale}...")
        current_image = run_tiled_quality_step(
            model=model,
            processor=processor,
            device=device,
            input_image=current_image,
            torch_module=torch,
            tile_size=tile_size,
            tile_overlap=DEFAULT_TILE_OVERLAP,
        )

    output_image = attach_alpha_if_needed(image=current_image, alpha_channel=alpha_channel)
    save_output_image(image=output_image, output_path=output_path)

    print()
    print("Upscale complete!")
    print(f"Output saved to: {output_path}")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Upscale an image with a local quality backend")
    parser.add_argument("input", help="Input image file")
    parser.add_argument("output", nargs="?", help="Optional output image path")
    parser.add_argument(
        "--scale",
        choices=["2", "4", "8", "16"],
        help="Upscale factor. If omitted, the tool asks in the CMD window.",
    )
    parser.add_argument(
        "--backend",
        choices=["quality", "fast"],
        default=DEFAULT_BACKEND,
        help="Backend to use. quality is the default; fast uses Real-ESRGAN.",
    )
    parser.add_argument(
        "--tile-size",
        default="auto",
        help="Quality backend tile size. Use auto or a multiple of 8 like 256 or 512.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])

    input_path = pathlib.Path(args.input).expanduser().resolve()
    if not input_path.exists():
        print(f"Error: File not found: {input_path}")
        return 1

    scale = int(args.scale) if args.scale else prompt_for_scale()
    backend = normalize_backend_name(args.backend)
    try:
        tile_size_override = normalize_tile_size_choice(args.tile_size)
    except ValueError as error:
        print(str(error))
        return 1
    output_path = (
        pathlib.Path(args.output).expanduser().resolve()
        if args.output
        else build_default_output_path(input_path=input_path, scale=scale)
    )

    if backend == "quality":
        return run_quality_upscale(
            input_path=input_path,
            output_path=output_path,
            scale=scale,
            tile_size_override=tile_size_override,
        )

    return run_fast_upscale(
        exe_dir=resolve_exe_dir(),
        input_path=input_path,
        output_path=output_path,
        scale=scale,
    )


if __name__ == "__main__":
    raise SystemExit(main())
