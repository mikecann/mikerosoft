"""Dependency-injected transcript processing primitives."""

from __future__ import annotations

from pathlib import Path
import math
from typing import Any, Protocol

from .manifest import VerifiedManifest


class AudioTranscriber(Protocol):
    def transcribe(self, path: Path, channel_origin: str) -> list[dict[str, Any]]:
        """Return timestamped transcript turns for one preserved source channel."""


class TranscriptProcessor:
    """Transcribe preserved channels separately and merge their timelines.

    Channel provenance describes where captured bytes came from. It is not a
    speaker identity: a room microphone may contain several people, while an
    incoming channel may contain every remote participant.
    """

    CHANNEL_KINDS = {
        "microphone_audio": "microphone",
        "incoming_audio": "incoming",
    }

    def __init__(self, transcriber: AudioTranscriber, source_offsets: dict[str, float] | None = None):
        self.transcriber = transcriber
        self.source_offsets = source_offsets or {}

    def process(
        self,
        archive_directory: Path | str,
        manifest: VerifiedManifest,
    ) -> dict[str, Any]:
        root = Path(archive_directory)
        turns: list[dict[str, Any]] = []
        sources: list[dict[str, str]] = []
        for item in manifest.files:
            channel_origin = self.CHANNEL_KINDS.get(item.kind)
            if channel_origin is None:
                continue
            path = root.joinpath(*item.path.split("/"))
            sources.append({"path": item.path, "channel_origin": channel_origin})
            for raw_turn in self.transcriber.transcribe(path, channel_origin):
                turn = self._validated_turn(raw_turn)
                offset = self.source_offsets.get(channel_origin, self.metadata_offset(manifest, channel_origin))
                turn["start"] += offset
                turn["end"] += offset
                turn["channel_origin"] = channel_origin
                turns.append(turn)
        turns.sort(key=lambda turn: (turn["start"], turn["end"], turn["channel_origin"]))
        return {
            "schema_version": 1,
            "meeting_id": manifest.meeting_id,
            "manifest_revision": manifest.revision,
            "sources": sources,
            "turns": turns,
        }

    @staticmethod
    def metadata_offset(manifest: VerifiedManifest, channel_origin: str) -> float:
        raw = manifest.metadata.get("tracks", {}).get(channel_origin, {})
        value = raw.get("firstOffset", raw.get("first_offset", 0.0)) if isinstance(raw, dict) else 0.0
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
            raise ValueError(f"Invalid {channel_origin} firstOffset in metadata.json.")
        return float(value)

    @staticmethod
    def _validated_turn(raw_turn: dict[str, Any]) -> dict[str, Any]:
        if not isinstance(raw_turn, dict):
            raise ValueError("A transcriber turn must be an object.")
        start = raw_turn.get("start")
        end = raw_turn.get("end")
        text = raw_turn.get("text")
        if (
            isinstance(start, bool)
            or not isinstance(start, (int, float))
            or isinstance(end, bool)
            or not isinstance(end, (int, float))
            or not math.isfinite(start)
            or not math.isfinite(end)
            or start < 0
            or end < start
            or not isinstance(text, str)
        ):
            raise ValueError("A transcriber turn needs valid start, end, and text fields.")
        result: dict[str, Any] = {"start": float(start), "end": float(end), "text": text}
        speaker = raw_turn.get("speaker")
        if speaker is not None:
            if not isinstance(speaker, str) or not speaker.strip():
                raise ValueError("A transcriber speaker label must be a nonempty string.")
            result["speaker"] = speaker
        return result


def timeline_offset(first_offset: float, container_start_time: float | None) -> float:
    """Return the first captured sample's offset on the shared session clock.

    AAC priming and container edit lists can move ``format.start_time`` before
    the first captured sample, including to a negative timestamp. Decoders
    already remove that representation. The capture metadata is therefore the
    only clock offset that should be added to decoded transcript timestamps.
    """
    del container_start_time
    if isinstance(first_offset, bool) or not math.isfinite(first_offset) or first_offset < 0:
        raise ValueError("Capture firstOffset must be finite and nonnegative.")
    return first_offset
