from __future__ import annotations

import importlib.util
import platform as host_platform
import threading
from dataclasses import dataclass

import numpy as np

SAMPLE_RATE = 16000

# mlx.core.clear_cache() affects the whole process, not one model instance.
# Preview and final models therefore share a lock even when they use different
# Whisper weights. Otherwise one thread can clear native working memory while
# the other is still running inference.
_MLX_INFERENCE_LOCK = threading.Lock()

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


def resolve_default_whisper_model(
    *,
    accelerated_model: str,
    fallback_model: str,
    cuda_available: bool,
    system: str,
    machine: str,
    has_mlx: bool | None = None,
) -> str:
    """Choose the accelerated model when the current hardware supports it."""
    if cuda_available:
        return accelerated_model

    mlx_repo = resolve_mlx_repo(
        system=system,
        machine=machine,
        model_name=accelerated_model,
        has_mlx=has_mlx,
    )
    return accelerated_model if mlx_repo else fallback_model


def resolve_local_default_whisper_model(
    *,
    accelerated_model: str,
    fallback_model: str,
    cuda_available: bool,
) -> str:
    return resolve_default_whisper_model(
        accelerated_model=accelerated_model,
        fallback_model=fallback_model,
        cuda_available=cuda_available,
        system=host_platform.system().lower(),
        machine=host_platform.machine(),
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
        from mlx import core as mlx_core
        import mlx_whisper

        self._mlx_core = mlx_core
        self._mlx_whisper = mlx_whisper
        self.repo_id = repo_id
        self._is_warmed = False
        self._inference_lock = _MLX_INFERENCE_LOCK

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
        with self._inference_lock:
            try:
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
            finally:
                self._mlx_core.clear_cache()

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


def load_local_mlx_model(
    *,
    model_name: str,
    repo_resolver=None,
    model_factory=None,
):
    """Load and warm an MLX Whisper model, or return None off Apple Silicon."""
    if repo_resolver is None:
        repo_resolver = resolve_local_mlx_repo
    if model_factory is None:
        model_factory = MlxWhisperModel

    repo_id = repo_resolver(model_name=model_name)
    if not repo_id:
        return None

    model = model_factory(repo_id=repo_id)
    model.warm()
    return model
