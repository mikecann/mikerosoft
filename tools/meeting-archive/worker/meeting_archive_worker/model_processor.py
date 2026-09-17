"""Lazy optional faster-whisper and pyannote adapter for Bruce."""

from __future__ import annotations

import json
import math
import os
import shutil
import stat
import subprocess
import tempfile
import uuid
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path
from typing import Any

from .durable_files import atomic_write_bytes, atomic_write_text
from .manifest import verify_incoming
from .processing import TranscriptProcessor, timeline_offset
from .queue import Job
from .speakers import SpeakerRegistry


PLAYBACK_PATH = "playback/meeting.mp4"
PLAYBACK_RECEIPT_PATH = "playback/meeting-playback.json"
PLAYBACK_RECIPE_VERSION = 2
RESERVED_GENERATED_NAMESPACES = frozenset({"playback", "transcripts"})


class WhisperPyannoteTranscriber:
    def __init__(self) -> None:
        token = os.environ.get("HF_TOKEN", "").strip()
        allow_without_diarization = os.environ.get(
            "MEETING_ARCHIVE_ALLOW_TRANSCRIPTION_WITHOUT_DIARIZATION",
            "",
        ) == "1"
        if not token and not allow_without_diarization:
            raise RuntimeError(
                "Speaker diarization is required but HF_TOKEN is unavailable. "
                "The job remains queued for retry after credential setup.",
            )
        try:
            from faster_whisper import WhisperModel
        except ImportError as error:
            raise RuntimeError("faster-whisper is not installed in the worker environment.") from error
        model = os.environ.get("MEETING_ARCHIVE_WHISPER_MODEL", "small.en")
        cpu_threads = max(
            1,
            min(4, int(os.environ.get("MEETING_ARCHIVE_WHISPER_CPU_THREADS", "2"))),
        )
        self.whisper = WhisperModel(
            model,
            device="cpu",
            compute_type="int8",
            cpu_threads=cpu_threads,
        )
        self.diarizer = None
        self.diarization_enabled = bool(token)
        self.embeddings: dict[str, list[float]] = {}
        if token:
            try:
                from pyannote.audio import Pipeline
            except ImportError as error:
                raise RuntimeError("pyannote.audio is not installed in the worker environment.") from error
            self.diarizer = Pipeline.from_pretrained(
                os.environ.get("MEETING_ARCHIVE_DIARIZATION_MODEL", "pyannote/speaker-diarization-community-1"),
                token=token,
            )

    def transcribe(self, path: Path, channel_origin: str) -> list[dict[str, Any]]:
        segments, _ = self.whisper.transcribe(str(path), vad_filter=True)
        turns = [
            {"start": float(item.start), "end": float(item.end), "text": item.text.strip()}
            for item in segments if item.text.strip()
        ]
        if self.diarizer is None:
            return turns
        output = self._diarize_without_torchcodec(path)
        annotation = getattr(output, "exclusive_speaker_diarization", None) or getattr(
            output, "speaker_diarization", output,
        )
        speaker_turns = []
        if hasattr(annotation, "itertracks"):
            speaker_turns = [
                (float(turn.start), float(turn.end), str(speaker))
                for turn, _track, speaker in annotation.itertracks(yield_label=True)
            ]
        # community-1 exposes one embedding per diarized speaker. Reuse those
        # outputs instead of loading a second model alongside the pipeline on
        # Bruce's 8 GB machine.
        raw_embeddings = getattr(output, "speaker_embeddings", {})
        # pyannote 4 orders this array by speaker_diarization.labels(), even
        # when exclusive diarization is used for the turn timeline.
        embedding_annotation = getattr(output, "speaker_diarization", annotation)
        self.embeddings.update(
            extract_speaker_embeddings(raw_embeddings, embedding_annotation, channel_origin),
        )
        for turn in turns:
            overlaps = [
                (max(0.0, min(turn["end"], end) - max(turn["start"], start)), speaker)
                for start, end, speaker in speaker_turns
            ]
            if overlaps and max(overlaps)[0] > 0:
                turn["speaker"] = f"{channel_origin}:{max(overlaps)[1]}"
        return turns

    def _diarize_without_torchcodec(self, path: Path):
        """Decode with ffmpeg 8, then pass a waveform so pyannote skips torchcodec."""
        ffmpeg = find_executable("ffmpeg")
        if ffmpeg is None:
            raise RuntimeError("ffmpeg is required for speaker diarization.")
        scratch = Path(os.environ.get("MEETING_ARCHIVE_SCRATCH", tempfile.gettempdir()))
        scratch.mkdir(parents=True, exist_ok=True)
        descriptor, raw_name = tempfile.mkstemp(prefix="meeting-audio-", suffix=".s16le", dir=scratch)
        os.close(descriptor)
        raw_path = Path(raw_name)
        try:
            subprocess.run(
                [ffmpeg, "-v", "error", "-threads", "1", "-i", str(path), "-vn", "-ac", "1", "-ar", "16000", "-f", "s16le", "-y", str(raw_path)],
                check=True,
            )
            sample_count = raw_path.stat().st_size // 2
            estimated_waveform_bytes = sample_count * 4
            memory_limit = int(
                os.environ.get(
                    "MEETING_ARCHIVE_MAX_DIARIZATION_MEMORY_BYTES",
                    str(1536 * 1024 * 1024),
                ),
            )
            if memory_limit <= 0:
                raise RuntimeError("MEETING_ARCHIVE_MAX_DIARIZATION_MEMORY_BYTES must be positive.")
            if estimated_waveform_bytes > memory_limit:
                hours = sample_count / 16000 / 3600
                raise RuntimeError(
                    f"The {hours:.1f} hour track needs about {estimated_waveform_bytes} bytes "
                    f"for diarization, above the {memory_limit}-byte memory budget. "
                    "Chunked diarization is not implemented yet; the complete source remains queued.",
                )
            import numpy as np
            import torch

            torch.set_num_threads(max(1, min(4, int(os.environ.get("MEETING_ARCHIVE_TORCH_THREADS", "2")))))
            samples = np.memmap(raw_path, mode="c", dtype="<i2")
            waveform = torch.from_numpy(samples).to(torch.float32).div_(32768.0).unsqueeze(0)
            return diarize_waveform(self.diarizer, waveform, 16000)
        finally:
            raw_path.unlink(missing_ok=True)


def diarize_waveform(pipeline, waveform, sample_rate: int):
    return pipeline({"waveform": waveform, "sample_rate": sample_rate})


def process(archive_directory: Path, job: Job) -> None:
    """CLI processor callable. Outputs are versioned and source files stay untouched."""
    manifest = verify_incoming(archive_directory)
    _assert_generated_namespaces_unowned(manifest)
    output = _ensure_real_generated_directory(
        archive_directory,
        ("transcripts", f"v{job.manifest_revision}"),
    )
    json_path = output / "transcript.json"
    if json_path.is_file():
        try:
            existing = json.loads(json_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise RuntimeError(f"Existing transcript checkpoint is unreadable: {error}") from error
        if (
            existing.get("meeting_id") != manifest.meeting_id
            or existing.get("manifest_revision") != manifest.revision
            or existing.get("processing", {}).get("manifest_sha256") != manifest.manifest_sha256
        ):
            raise RuntimeError("Existing transcript provenance does not match this manifest.")
        # transcript.json is the processing receipt. Observations are committed
        # before that receipt, while these derived views can always be rebuilt.
        _refresh_confirmed_names(existing, os.environ.get("MEETING_ARCHIVE_WORKER_DB"))
        _write_transcript_artifacts(output, existing)
        create_playback(archive_directory, manifest)
        return
    transcriber = WhisperPyannoteTranscriber()
    offsets = {}
    for item in manifest.files:
        origin = TranscriptProcessor.CHANNEL_KINDS.get(item.kind)
        if origin:
            first = TranscriptProcessor.metadata_offset(manifest, origin)
            offsets[origin] = timeline_offset(first, probe_start_time(archive_directory / item.path))
    result = TranscriptProcessor(transcriber, offsets).process(archive_directory, manifest)
    result["processing"] = {
        "manifest_sha256": manifest.manifest_sha256,
        "whisper_model": os.environ.get("MEETING_ARCHIVE_WHISPER_MODEL", "small.en"),
        "diarization_model": os.environ.get(
            "MEETING_ARCHIVE_DIARIZATION_MODEL",
            "pyannote/speaker-diarization-community-1",
        ),
        "diarization_status": "enabled" if transcriber.diarization_enabled else "explicitly_disabled",
    }
    try:
        result["processing"]["pyannote_audio_version"] = version("pyannote.audio")
    except PackageNotFoundError:
        result["processing"]["pyannote_audio_version"] = "unavailable"
    embedding_model_id = (
        f"{result['processing']['diarization_model']}@"
        f"{result['processing']['pyannote_audio_version']}"
    )
    worker_db = os.environ.get("MEETING_ARCHIVE_WORKER_DB")
    if worker_db:
        registry = SpeakerRegistry(worker_db)
        for speaker_id, embedding in transcriber.embeddings.items():
            registry.save_observation(
                manifest.meeting_id,
                manifest.revision,
                speaker_id,
                embedding,
                embedding_model_id,
            )
        confirmed = registry.assignments(manifest.meeting_id, manifest.revision)
        for turn in result["turns"]:
            speaker_id = turn.get("speaker")
            embedding = transcriber.embeddings.get(speaker_id) if speaker_id else None
            name = confirmed.get(speaker_id) if speaker_id else None
            if name is None and embedding is not None:
                name = registry.suggest(embedding, model_id=embedding_model_id)
            if name:
                turn["name"] = name
        # SQLite commits each observation before transcript.json becomes the
        # durable processing receipt used to skip expensive model work.
        result["processing"]["speaker_observations_committed"] = True
    else:
        result["processing"]["speaker_observations_committed"] = False
    _write_transcript_artifacts(output, result)
    create_playback(archive_directory, manifest)


def _refresh_confirmed_names(result: dict[str, Any], worker_db: str | None) -> None:
    if not worker_db:
        return
    registry = SpeakerRegistry(worker_db)
    assignments = registry.assignments(result["meeting_id"], result["manifest_revision"])
    for turn in result.get("turns", []):
        speaker_id = turn.get("speaker")
        if speaker_id in assignments:
            turn["name"] = assignments[speaker_id]


def render_markdown(result: dict[str, Any]) -> str:
    lines = ["# Transcript", ""]
    for turn in result.get("turns", []):
        label = turn.get("name", turn.get("speaker", turn["channel_origin"]))
        lines.append(f"- **{label}** [{turn['start']:.1f}s] {turn['text']}")
    return "\n".join(lines) + "\n"


def _write_transcript_artifacts(output: Path, result: dict[str, Any]) -> None:
    """Rebuild Markdown first and commit JSON last as the durable receipt."""

    output.mkdir(parents=True, exist_ok=True)
    markdown_path = output / "transcript.md"
    markdown = render_markdown(result)
    if not markdown_path.is_file() or markdown_path.read_text(encoding="utf-8") != markdown:
        atomic_write_text(markdown_path, markdown)
    json_path = output / "transcript.json"
    encoded = (json.dumps(result, sort_keys=True, ensure_ascii=False, indent=2) + "\n").encode()
    if not json_path.is_file() or json_path.read_bytes() != encoded:
        atomic_write_bytes(json_path, encoded)


def extract_speaker_embeddings(raw_embeddings, annotation, channel_origin: str) -> dict[str, list[float]]:
    labels = annotation.labels() if hasattr(annotation, "labels") else []
    items = raw_embeddings.items() if isinstance(raw_embeddings, dict) else zip(
        labels,
        [] if raw_embeddings is None else raw_embeddings,
    )
    result = {}
    for speaker, raw in items:
        values = raw.tolist() if hasattr(raw, "tolist") else list(raw)
        while values and isinstance(values[0], list):
            values = values[0]
        result[f"{channel_origin}:{speaker}"] = [float(value) for value in values]
    return result


def create_playback(archive_directory: Path, manifest) -> Path | None:
    """Build browser-compatible playback without touching preserved sources."""
    _assert_generated_namespaces_unowned(manifest)
    video = next((item for item in manifest.files if item.kind == "video"), None)
    audio = [item for item in manifest.files if item.kind in ("microphone_audio", "incoming_audio")]
    if video is None or not audio:
        return None
    playback_directory = _ensure_real_generated_directory(archive_directory, ("playback",))
    output = playback_directory / "meeting.mp4"
    receipt_path = playback_directory / "meeting-playback.json"
    recipe = _playback_recipe(manifest, video, audio)
    if _is_regular_non_symlink(output) and _playback_receipt_matches(receipt_path, recipe) and _playback_is_h264(output):
        return output
    ffmpeg = find_executable("ffmpeg")
    if ffmpeg is None:
        raise RuntimeError("ffmpeg is required to create the playback asset.")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.parent / f".{output.name}.{uuid.uuid4().hex}.part.mp4"
    command = [
        ffmpeg, "-hide_banner", "-loglevel", "error", "-threads", "2",
        "-i", str(archive_directory / video.path),
    ]
    for item in audio:
        command.extend(["-i", str(archive_directory / item.path)])

    # AVAssetWriter uses a shared host-clock origin, recorded as firstOffset in
    # metadata. Decode away each file's independent AAC priming/edit list,
    # normalize that decoded track to zero, then apply the capture offset once.
    video_offset = _playback_track_offset(manifest, "video")
    filters = [f"[0:v:0]setpts=PTS-STARTPTS+{_ffmpeg_number(video_offset)}/TB[v]"]
    audio_labels = []
    for index, item in enumerate(audio, start=1):
        origin = TranscriptProcessor.CHANNEL_KINDS[item.kind]
        offset = _playback_track_offset(manifest, origin)
        label = f"a{index}"
        delay_milliseconds = _ffmpeg_number(offset * 1_000)
        filters.append(
            f"[{index}:a:0]asetpts=PTS-STARTPTS,adelay={delay_milliseconds}:all=1[{label}]"
        )
        audio_labels.append(f"[{label}]")
    if len(audio_labels) == 1:
        audio_map = audio_labels[0]
    else:
        filters.append(
            f"{''.join(audio_labels)}amix=inputs={len(audio_labels)}:duration=longest[a]"
        )
        audio_map = "[a]"

    base = command + [
        "-filter_complex", ";".join(filters),
        "-map", "[v]", "-map", audio_map,
        "-pix_fmt", "yuv420p", "-tag:v", "avc1", "-fps_mode:v", "passthrough",
        "-profile:v", "high", "-level:v", "4.1",
        "-b:v", "4M", "-maxrate:v", "6M", "-bufsize:v", "8M",
        "-threads:v", "2", "-c:a", "aac", "-movflags", "+faststart", "-y",
    ]
    last_error: subprocess.CalledProcessError | None = None
    encoders = ("h264_videotoolbox",) if os.environ.get(
        "MEETING_ARCHIVE_REQUIRE_HARDWARE_H264", ""
    ) == "1" else ("h264_videotoolbox", "libx264")
    try:
        for encoder in encoders:
            temporary.unlink(missing_ok=True)
            try:
                subprocess.run(
                    base + ["-c:v", encoder, str(temporary)],
                    check=True,
                    capture_output=True,
                    text=True,
                )
                last_error = None
                break
            except subprocess.CalledProcessError as error:
                last_error = error
        if last_error is not None:
            raise RuntimeError("No working H.264 playback encoder is available.") from last_error
        os.replace(temporary, output)
        atomic_write_text(
            receipt_path,
            json.dumps(recipe, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        )
    finally:
        temporary.unlink(missing_ok=True)
    return output


def _assert_generated_namespaces_unowned(manifest) -> None:
    for item in manifest.files:
        namespace = item.path.split("/", 1)[0].casefold()
        if namespace in RESERVED_GENERATED_NAMESPACES:
            raise RuntimeError(
                f"accepted source {item.path} occupies reserved generated namespace {namespace}/."
            )


def _is_regular_non_symlink(path: Path) -> bool:
    try:
        mode = path.lstat().st_mode
    except OSError:
        return False
    return stat.S_ISREG(mode)


def _ensure_real_generated_directory(root: Path, components: tuple[str, ...]) -> Path:
    current = root
    for component in components:
        current = current / component
        try:
            current.mkdir()
        except FileExistsError:
            pass
        try:
            mode = current.lstat().st_mode
        except OSError as error:
            raise RuntimeError(f"Generated path {current} is not available: {error}") from error
        if not stat.S_ISDIR(mode):
            relative = current.relative_to(root)
            raise RuntimeError(f"Generated path {relative} must be a real directory, not a symlink or file.")
    return current


def _playback_recipe(manifest, video, audio) -> dict[str, Any]:
    sources = [video, *audio]
    offsets = {"video": _playback_track_offset(manifest, "video")}
    for item in audio:
        origin = TranscriptProcessor.CHANNEL_KINDS[item.kind]
        offsets[origin] = _playback_track_offset(manifest, origin)
    return {
        "schema_version": 1,
        "recipe_version": PLAYBACK_RECIPE_VERSION,
        "sources": [
            {
                "path": item.path,
                "size_bytes": item.size_bytes,
                "sha256": item.sha256,
                "kind": item.kind,
            }
            for item in sources
        ],
        "first_offsets": offsets,
    }


def _playback_receipt_matches(path: Path, expected: dict[str, Any]) -> bool:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    return value == expected


def _playback_track_offset(manifest, track: str) -> float:
    metadata = getattr(manifest, "metadata", {})
    tracks = metadata.get("tracks", {}) if isinstance(metadata, dict) else {}
    raw = tracks.get(track, {}) if isinstance(tracks, dict) else {}
    value = raw.get("firstOffset", raw.get("first_offset", 0.0)) if isinstance(raw, dict) else 0.0
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise ValueError(f"Invalid {track} firstOffset in metadata.json.")
    return float(value)


def _ffmpeg_number(value: float) -> str:
    return f"{value:.9f}".rstrip("0").rstrip(".") or "0"


def _playback_is_h264(path: Path) -> bool:
    ffprobe = find_executable("ffprobe")
    if ffprobe is None:
        return True
    try:
        completed = subprocess.run(
            [
                ffprobe, "-v", "error", "-select_streams", "v:0",
                "-show_entries", "stream=codec_name", "-of", "default=nw=1:nk=1", str(path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return False
    return completed.stdout.strip().lower() == "h264"


def probe_start_time(path: Path) -> float | None:
    ffprobe = find_executable("ffprobe")
    if ffprobe is None:
        return None
    completed = subprocess.run(
        [ffprobe, "-v", "error", "-show_entries", "format=start_time", "-of", "default=nw=1:nk=1", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    value = completed.stdout.strip()
    return float(value) if value and value != "N/A" else None


def find_executable(name: str) -> str | None:
    found = shutil.which(name)
    if found:
        return found
    for root in (Path("/opt/homebrew/bin"), Path("/usr/local/bin"), Path.home() / ".local/bin"):
        candidate = root / name
        if candidate.is_file():
            return str(candidate)
    return None
