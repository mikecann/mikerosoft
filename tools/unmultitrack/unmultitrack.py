from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


MP4_LIKE_EXTENSIONS = {".mp4", ".m4v", ".mov"}
STREAM_RE = re.compile(
    r"^\s*Stream #(?P<input>\d+):(?P<stream>\d+)"
    r"(?:\[[^\]]+\])?"
    r"(?:\([^)]+\))?"
    r": (?P<kind>Video|Audio|Subtitle|Data|Attachment): (?P<details>.*)$",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class StreamInfo:
    input_index: int
    kind: str
    codec: str = ""
    details: str = ""


@dataclass(frozen=True)
class DemuxJob:
    video_position: int
    input_stream_index: int
    output_path: Path
    command: list[str]


def parse_ffmpeg_streams(output: str) -> list[StreamInfo]:
    streams: list[StreamInfo] = []
    for line in output.splitlines():
        match = STREAM_RE.match(line)
        if not match:
            continue

        details = match.group("details").strip()
        codec = details.split(",", 1)[0].strip()
        streams.append(
            StreamInfo(
                input_index=int(match.group("stream")),
                kind=match.group("kind").lower(),
                codec=codec,
                details=details,
            )
        )

    return streams


def streams_from_ffprobe_json(payload: dict[str, Any] | str) -> list[StreamInfo]:
    data = json.loads(payload) if isinstance(payload, str) else payload
    streams: list[StreamInfo] = []

    for stream in data.get("streams", []):
        kind = str(stream.get("codec_type", "")).lower()
        if kind not in {"video", "audio", "subtitle", "data", "attachment"}:
            continue

        streams.append(
            StreamInfo(
                input_index=int(stream["index"]),
                kind=kind,
                codec=str(stream.get("codec_name", "") or ""),
                details="",
            )
        )

    return streams


def candidate_binary_paths(name: str) -> Iterable[Path]:
    names = [f"{name}.exe", name] if os.name == "nt" else [name, f"{name}.exe"]

    exedir = os.environ.get("EXEDIR")
    if exedir:
        for exe_name in names:
            yield Path(exedir) / exe_name

    if os.name == "nt":
        for exe_name in names:
            yield Path(r"C:\dev\tools") / exe_name

    for exe_name in names:
        found = shutil.which(exe_name)
        if found:
            yield Path(found)


def find_binary(name: str, required: bool = True) -> Path | None:
    seen: set[Path] = set()
    for candidate in candidate_binary_paths(name):
        normalized = candidate.resolve() if candidate.exists() else candidate
        if normalized in seen:
            continue
        seen.add(normalized)
        if candidate.exists():
            return candidate

    if required:
        raise FileNotFoundError(f"{name} was not found. Put {name}.exe in C:\\dev\\tools or on PATH.")
    return None


def probe_streams(input_path: Path, ffmpeg: Path, ffprobe: Path | None) -> list[StreamInfo]:
    if ffprobe is not None:
        command = [
            str(ffprobe),
            "-v",
            "error",
            "-show_entries",
            "stream=index,codec_type,codec_name",
            "-of",
            "json",
            str(input_path),
        ]
        result = subprocess.run(command, capture_output=True, text=True, errors="replace")
        if result.returncode == 0:
            streams = streams_from_ffprobe_json(result.stdout)
            if streams:
                return streams

    result = subprocess.run(
        [str(ffmpeg), "-hide_banner", "-i", str(input_path)],
        capture_output=True,
        text=True,
        errors="replace",
    )
    streams = parse_ffmpeg_streams(result.stderr + "\n" + result.stdout)
    if not streams:
        raise RuntimeError("Could not read streams from ffmpeg output.")
    return streams


def default_output_dir(input_path: Path) -> Path:
    return input_path.with_name(f"{input_path.stem}_unmultitracked")


def next_available_path(path: Path, taken: Iterable[Path] = ()) -> Path:
    reserved = {p.resolve() if p.exists() else p for p in taken}
    if not path.exists() and path not in reserved:
        return path

    for index in range(2, 10000):
        candidate = path.with_name(f"{path.stem}_{index}{path.suffix}")
        if not candidate.exists() and candidate not in reserved:
            return candidate

    raise RuntimeError(f"Could not find an unused output path for {path}")


def output_extension(input_path: Path) -> str:
    return input_path.suffix if input_path.suffix else ".mp4"


def build_demux_command(
    ffmpeg: Path,
    input_path: Path,
    video_position: int,
    output_path: Path,
    include_audio: bool = True,
    overwrite: bool = False,
) -> list[str]:
    command = [
        str(ffmpeg),
        "-hide_banner",
        "-stats",
        "-y" if overwrite else "-n",
        "-i",
        str(input_path),
        "-map",
        f"0:v:{video_position}",
    ]

    if include_audio:
        command += ["-map", "0:a?"]

    command += ["-map_metadata", "0", "-c", "copy"]

    if output_path.suffix.lower() in MP4_LIKE_EXTENSIONS:
        command += ["-movflags", "+faststart"]

    command.append(str(output_path))
    return command


def build_output_plan(
    ffmpeg: Path,
    input_path: Path,
    streams: list[StreamInfo],
    output_dir: Path | None = None,
    include_audio: bool = True,
    overwrite: bool = False,
    allow_single: bool = False,
) -> list[DemuxJob]:
    video_streams = [stream for stream in streams if stream.kind == "video"]
    if not video_streams:
        raise ValueError("No video streams found.")
    if len(video_streams) == 1 and not allow_single:
        raise ValueError(
            "Only one video stream found. This does not look like a multi-track recording. "
            "Use --allow-single if you really want to copy it anyway."
        )

    target_dir = output_dir or default_output_dir(input_path)
    extension = output_extension(input_path)
    jobs: list[DemuxJob] = []
    taken: list[Path] = []

    for position, stream in enumerate(video_streams):
        output_path = target_dir / f"{input_path.stem}_v{position + 1}{extension}"
        if not overwrite:
            output_path = next_available_path(output_path, taken)
        taken.append(output_path)

        jobs.append(
            DemuxJob(
                video_position=position,
                input_stream_index=stream.input_index,
                output_path=output_path,
                command=build_demux_command(
                    ffmpeg=ffmpeg,
                    input_path=input_path,
                    video_position=position,
                    output_path=output_path,
                    include_audio=include_audio,
                    overwrite=overwrite,
                ),
            )
        )

    return jobs


def quote_command(command: list[str]) -> str:
    return " ".join(f'"{part}"' if " " in part else part for part in command)


def print_stream_summary(streams: list[StreamInfo]) -> None:
    video_streams = [stream for stream in streams if stream.kind == "video"]
    audio_streams = [stream for stream in streams if stream.kind == "audio"]
    print(f"Streams: {len(video_streams)} video, {len(audio_streams)} audio")
    for stream in streams:
        if stream.kind not in {"video", "audio"}:
            continue
        label = f"#{stream.input_index}"
        codec = f" ({stream.codec})" if stream.codec else ""
        print(f"  {label:<4} {stream.kind}{codec}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract each video stream from a multi-track recording into its own file.",
    )
    parser.add_argument("input", help="Multi-track video file to demux")
    parser.add_argument("-o", "--output-dir", type=Path, help="Directory for extracted files")
    parser.add_argument("--video-only", action="store_true", help="Do not copy audio streams into each output")
    parser.add_argument("--overwrite", action="store_true", help="Overwrite existing output files")
    parser.add_argument("--allow-single", action="store_true", help="Allow files with only one video stream")
    parser.add_argument("--dry-run", action="store_true", help="Print ffmpeg commands without running them")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    input_path = Path(args.input)

    try:
        input_path = input_path.resolve(strict=True)
        if not input_path.is_file():
            raise FileNotFoundError(f"Input is not a file: {input_path}")

        ffmpeg = find_binary("ffmpeg", required=True)
        assert ffmpeg is not None
        ffprobe = find_binary("ffprobe", required=False)

        print("Un-multi-track video")
        print(f"Input : {input_path}")
        if ffprobe is None:
            print("Probe : ffprobe not found, using ffmpeg stream output")
        else:
            print(f"Probe : {ffprobe}")

        streams = probe_streams(input_path=input_path, ffmpeg=ffmpeg, ffprobe=ffprobe)
        print_stream_summary(streams)

        jobs = build_output_plan(
            ffmpeg=ffmpeg,
            input_path=input_path,
            streams=streams,
            output_dir=args.output_dir.resolve() if args.output_dir else None,
            include_audio=not args.video_only,
            overwrite=args.overwrite,
            allow_single=args.allow_single,
        )

        if args.dry_run:
            print("")
            print("Dry run:")
            for job in jobs:
                print(quote_command(job.command))
            return 0

        jobs[0].output_path.parent.mkdir(parents=True, exist_ok=True)

        print("")
        for index, job in enumerate(jobs, start=1):
            print(f"[{index}/{len(jobs)}] Stream #{job.input_stream_index} -> {job.output_path.name}")
            result = subprocess.run(job.command)
            if result.returncode != 0:
                return result.returncode

        print("")
        print("Done:")
        for job in jobs:
            print(f"  {job.output_path}")
        return 0
    except Exception as exc:
        print("")
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
