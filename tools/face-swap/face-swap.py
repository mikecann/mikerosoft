#!/usr/bin/env python3
"""Face swapping using InsightFace inswapper_128.

Usage:
  python face-swap.py --target <path> --source <path> --output <path> [--model <path>]

--target  Image to modify (face in this image gets replaced)
--source  Donor face image (face taken from here)
--output  Where to write the result
--model   Optional path to inswapper_128.onnx (defaults to %LOCALAPPDATA%/face-swap/models/inswapper_128.onnx)
"""

import argparse
import os
import sys


def get_default_model_path() -> str:
    local_app_data = os.environ.get("LOCALAPPDATA", os.path.expanduser("~"))
    return os.path.join(local_app_data, "face-swap", "models", "inswapper_128.onnx")


def get_largest_face(faces):
    if not faces:
        return None
    return max(faces, key=lambda f: (f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1]))


def load_image(path: str):
    import cv2
    img = cv2.imread(path)
    if img is None:
        raise ValueError(f"Could not load image: {path}")
    return img


def main():
    parser = argparse.ArgumentParser(description="Swap a face in a target image")
    parser.add_argument("--target", required=True, help="Target image (face to replace)")
    parser.add_argument("--source", required=True, help="Source face image (donor face)")
    parser.add_argument("--output", required=True, help="Output image path")
    parser.add_argument("--model", default=None, help="Path to inswapper_128.onnx model")
    args = parser.parse_args()

    model_path = args.model or get_default_model_path()

    if not os.path.exists(model_path):
        print(f"ERROR: Model not found at: {model_path}", file=sys.stderr)
        print("Download inswapper_128.onnx from:", file=sys.stderr)
        print("  https://huggingface.co/thebiglaskowski/inswapper_128.onnx/resolve/main/inswapper_128.onnx?download=true", file=sys.stderr)
        print(f"Save it to: {model_path}", file=sys.stderr)
        sys.exit(1)

    try:
        import cv2
        import insightface
        from insightface.app import FaceAnalysis
        print("Dependencies loaded successfully.", flush=True)
    except ImportError as e:
        print(f"ERROR: Missing dependency - {e}", file=sys.stderr, flush=True)
        print("Run: pip install insightface onnxruntime opencv-python", file=sys.stderr, flush=True)
        sys.exit(1)

    print("Loading images...", flush=True)
    target_img = load_image(args.target)
    source_img = load_image(args.source)
    print(f"Target image size: {target_img.shape[1]}x{target_img.shape[0]}", flush=True)
    print(f"Source image size: {source_img.shape[1]}x{source_img.shape[0]}", flush=True)

    print("Initializing face detection model (buffalo_l)...", flush=True)
    providers = ["CUDAExecutionProvider", "CPUExecutionProvider"]
    app = FaceAnalysis(name="buffalo_l", providers=providers)
    app.prepare(ctx_id=0, det_size=(640, 640))

    print(f"Loading face swapper model from {model_path}...", flush=True)
    import onnxruntime
    swapper = insightface.model_zoo.get_model(model_path, download=False, download_zip=False)
    # Re-initialize the session with our providers to ensure it uses GPU if available
    swapper.session = onnxruntime.InferenceSession(model_path, providers=providers)

    print("Detecting face in source image...", flush=True)
    source_face = get_largest_face(app.get(source_img))
    if source_face is None:
        print("ERROR: No face detected in source image", file=sys.stderr, flush=True)
        sys.exit(1)

    print("Detecting faces in target image...", flush=True)
    target_faces = app.get(target_img)
    if not target_faces:
        print("ERROR: No face detected in target image", file=sys.stderr, flush=True)
        sys.exit(1)

    print(f"Found {len(target_faces)} face(s) in target image. Starting swap...", flush=True)
    result = target_img.copy()
    for i, face in enumerate(target_faces):
        print(f"Swapping face {i+1} of {len(target_faces)}...", flush=True)
        try:
            result = swapper.get(result, face, source_face, paste_back=True)
        except Exception as e:
            print(f"WARNING: Failed to swap face {i+1}: {e}", file=sys.stderr, flush=True)

    print(f"Saving output to {args.output}...", flush=True)
    out_dir = os.path.dirname(os.path.abspath(args.output))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    import cv2 as _cv2
    success = _cv2.imwrite(args.output, result)
    if not success:
        print(f"ERROR: Could not write output: {args.output}", file=sys.stderr, flush=True)
        sys.exit(1)

    print(f"SUCCESS: {args.output}", flush=True)


if __name__ == "__main__":
    main()
