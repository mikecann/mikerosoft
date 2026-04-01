#!/usr/bin/env python3
"""Face swapping using InsightFace inswapper_128.

Usage:
  python face-swap.py --target <path> --source <path> --output <path> [--model <path>]

--target  Image or video to modify (face in this media gets replaced)
--source  Donor face image (face taken from here)
--output  Where to write the result
--model   Optional path to inswapper_128.onnx (defaults to %LOCALAPPDATA%/face-swap/models/inswapper_128.onnx)
"""

import argparse
import os
import sys
import time
import subprocess


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


def is_video(path: str) -> bool:
    ext = os.path.splitext(path)[1].lower()
    return ext in ['.mp4', '.avi', '.mov', '.mkv', '.webm']


def process_image(target_path, source_face, app, swapper, output_path):
    import cv2
    print("Loading target image...", flush=True)
    target_img = load_image(target_path)
    print(f"Target image size: {target_img.shape[1]}x{target_img.shape[0]}", flush=True)

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

    print(f"Saving output to {output_path}...", flush=True)
    success = cv2.imwrite(output_path, result)
    if not success:
        print(f"ERROR: Could not write output: {output_path}", file=sys.stderr, flush=True)
        sys.exit(1)


def process_video(target_path, source_face, app, swapper, output_path):
    import cv2
    print(f"Opening target video: {target_path}", flush=True)
    cap = cv2.VideoCapture(target_path)
    if not cap.isOpened():
        print(f"ERROR: Could not open video: {target_path}", file=sys.stderr, flush=True)
        sys.exit(1)

    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = cap.get(cv2.CAP_PROP_FPS)
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))

    print(f"Video Info: {width}x{height} @ {fps}fps, {total_frames} frames", flush=True)

    temp_output = output_path + ".temp.mp4"
    fourcc = cv2.VideoWriter_fourcc(*'mp4v')
    out = cv2.VideoWriter(temp_output, fourcc, fps, (width, height))

    start_time = time.time()
    frame_count = 0

    print("Starting video processing...", flush=True)
    while True:
        ret, frame = cap.read()
        if not ret:
            break

        frame_count += 1
        if frame_count % 10 == 0 or frame_count == 1:
            elapsed = time.time() - start_time
            current_fps = frame_count / elapsed if elapsed > 0 else 0
            print(f"Processing frame {frame_count}/{total_frames} ({current_fps:.2f} fps)...", flush=True)

        target_faces = app.get(frame)
        result_frame = frame.copy()
        if target_faces:
            for face in target_faces:
                try:
                    result_frame = swapper.get(result_frame, face, source_face, paste_back=True)
                except Exception as e:
                    pass
        
        out.write(result_frame)

    cap.release()
    out.release()

    total_time = time.time() - start_time
    print(f"Finished processing {frame_count} frames in {total_time:.2f} seconds ({frame_count/total_time:.2f} fps).", flush=True)
    
    print("Muxing audio with ffmpeg...", flush=True)
    # Use ffmpeg to combine the new video with the original audio
    # -map 0:v:0 maps the video from the first input (temp_output)
    # -map 1:a:0? maps the audio from the second input (target_path), ? makes it optional if no audio exists
    # -c:v libx264 encodes video to standard h264 for best compatibility
    # -c:a aac encodes audio to aac
    # -y overwrites output
    cmd = [
        "ffmpeg", "-y",
        "-i", temp_output,
        "-i", target_path,
        "-map", "0:v:0",
        "-map", "1:a:0?",
        "-c:v", "libx264",
        "-preset", "fast",
        "-crf", "23",
        "-c:a", "aac",
        output_path
    ]
    
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as e:
        print(f"ERROR: ffmpeg muxing failed: {e.stderr.decode()}", file=sys.stderr, flush=True)
        if os.path.exists(temp_output):
            os.remove(temp_output)
        sys.exit(1)
        
    if os.path.exists(temp_output):
        os.remove(temp_output)


def main():
    parser = argparse.ArgumentParser(description="Swap a face in a target image or video")
    parser.add_argument("--target", required=True, help="Target image or video (face to replace)")
    parser.add_argument("--source", required=True, help="Source face image (donor face)")
    parser.add_argument("--output", required=True, help="Output file path")
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
        import onnxruntime
        print("Dependencies loaded successfully.", flush=True)
    except ImportError as e:
        print(f"ERROR: Missing dependency - {e}", file=sys.stderr, flush=True)
        print("Run: pip install insightface onnxruntime opencv-python", file=sys.stderr, flush=True)
        sys.exit(1)

    print("Loading source image...", flush=True)
    source_img = load_image(args.source)
    print(f"Source image size: {source_img.shape[1]}x{source_img.shape[0]}", flush=True)

    print("Initializing face detection model (buffalo_l)...", flush=True)
    providers = ["CUDAExecutionProvider", "CPUExecutionProvider"]
    app = FaceAnalysis(name="buffalo_l", providers=providers)
    app.prepare(ctx_id=0, det_size=(640, 640))

    print(f"Loading face swapper model from {model_path}...", flush=True)
    swapper = insightface.model_zoo.get_model(model_path, download=False, download_zip=False)
    # Re-initialize the session with our providers to ensure it uses GPU if available
    swapper.session = onnxruntime.InferenceSession(model_path, providers=providers)

    print("Detecting face in source image...", flush=True)
    source_face = get_largest_face(app.get(source_img))
    if source_face is None:
        print("ERROR: No face detected in source image", file=sys.stderr, flush=True)
        sys.exit(1)

    out_dir = os.path.dirname(os.path.abspath(args.output))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    if is_video(args.target):
        process_video(args.target, source_face, app, swapper, args.output)
    else:
        process_image(args.target, source_face, app, swapper, args.output)

    print(f"SUCCESS: {args.output}", flush=True)


if __name__ == "__main__":
    main()
