from __future__ import annotations

import importlib.util
import platform as host_platform
from dataclasses import dataclass

import numpy as np

SAMPLE_RATE = 16000

MLX_REPOS_BY_MODEL = {
    "tiny.en": "mlx-community/whisper-tiny.en-mlx",
    "base.en": "mlx-community/whisper-base.en-mlx",
    "small.en": "mlx-community/whisper-small.en-mlx",
    "medium.en": "mlx-community/whisper-medium-mlx",
    "large-v2": "mlx-community/whisper-large-v2-mlx",
    "large-v3": "mlx-community/whisper-large-v3-mlx",
    "large-v3-turbo": "mlx-community/whisper-large-v3-turbo",
}


def has_mlx_whisper() -> bool:
    return importlib.util.find_spec("mlx_whisper") is not None


def resolve_mlx_repo(
    *,
    system: str,
    machine: str,
    model_name: str,
    has_mlx: bool | None = None,
) -> str | None:
    if system != "darwin":
        return None

    normalized_machine = machine.lower()
    if normalized_machine not in {"arm64", "aarch64"}:
        return None

    if has_mlx is None:
        has_mlx = has_mlx_whisper()
    if not has_mlx:
        return None

    return MLX_REPOS_BY_MODEL.get(model_name)


def resolve_local_mlx_repo(*, model_name: str) -> str | None:
    return resolve_mlx_repo(
        system=host_platform.system().lower(),
        machine=host_platform.machine(),
        model_name=model_name,
    )


@dataclass(frozen=True)
class MlxSegment:
    text: str


@dataclass(frozen=True)
class MlxInfo:
    language: str
    language_probability: float


class MlxWhisperModel:
    def __init__(self, *, repo_id: str):
        import mlx_whisper

        self._mlx_whisper = mlx_whisper
        self.repo_id = repo_id
        self._is_warmed = False

    def warm(self) -> None:
        if self._is_warmed:
            return

        silence = np.zeros(int(0.5 * SAMPLE_RATE), dtype=np.float32)
        self.transcribe(
            silence,
            language="en",
            condition_on_previous_text=False,
            verbose=False,
        )
        self._is_warmed = True

    def transcribe(self, audio, **kwargs):
        result = self._mlx_whisper.transcribe(
            np.asarray(audio, dtype=np.float32),
            path_or_hf_repo=self.repo_id,
            language=kwargs.get("language", "en"),
            condition_on_previous_text=kwargs.get("condition_on_previous_text", False),
            verbose=kwargs.get("verbose", False),
        )
        segments = self._segments_from_result(result)
        info = MlxInfo(
            language=str(result.get("language") or "en"),
            language_probability=float(result.get("language_probability") or 1.0),
        )
        return segments, info

    def _segments_from_result(self, result: dict) -> list[MlxSegment]:
        parts = [
            MlxSegment(str(segment.get("text", "")).strip())
            for segment in result.get("segments", [])
            if str(segment.get("text", "")).strip()
        ]
        if parts:
            return parts

        text = str(result.get("text") or "").strip()
        if not text:
            return []
        return [MlxSegment(text)]
