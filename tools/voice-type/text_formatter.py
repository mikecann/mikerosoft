from __future__ import annotations

import dataclasses
import os
import re
import threading
from collections import Counter
from typing import Callable


DEFAULT_FORMATTER_SYSTEM_PROMPT = """You are a transcription cleaner.

Lightly format speech-to-text output.
Preserve the original meaning, wording, uncertainty, and tone.
Do not add information.
Do not remove information unless it is an obvious duplicate caused by transcription.
Do not summarize.
Do not rewrite for style.
Only fix punctuation, capitalization, paragraph breaks, and obvious transcription artifacts.
If unsure, return the text unchanged.
Return only the cleaned transcript.
"""
FORMATTER_SYSTEM_PROMPT = DEFAULT_FORMATTER_SYSTEM_PROMPT

SUPPORTED_FORMATTER_MODES = {"final_only", "hybrid", "precompute"}
MAX_LENGTH_CHANGE_RATIO = 0.22
MIN_TOKEN_OVERLAP_RATIO = 0.72

_WORD_RE = re.compile(r"[A-Za-z0-9]+(?:['-][A-Za-z0-9]+)*")
_NUMBER_RE = re.compile(r"\b\d+(?:[\d,.:/-]*\d)?\b")
_URL_RE = re.compile(r"(https?://\S+|www\.\S+|\b\S+@\S+\.\S+\b)", re.IGNORECASE)
_ACRONYM_RE = re.compile(r"\b[A-Z]{2,}\b")


@dataclasses.dataclass(frozen=True)
class FormatterModelPreset:
    key: str
    label: str
    repo_id: str
    filename: str


FORMATTER_MODEL_PRESETS = {
    "qwen2.5-1.5b": FormatterModelPreset(
        key="qwen2.5-1.5b",
        label="Qwen2.5 1.5B Instruct (stronger cleanup)",
        repo_id="Qwen/Qwen2.5-1.5B-Instruct-GGUF",
        filename="qwen2.5-1.5b-instruct-q4_k_m.gguf",
    ),
    "smollm2-1.7b": FormatterModelPreset(
        key="smollm2-1.7b",
        label="SmolLM2 1.7B Instruct",
        repo_id="HuggingFaceTB/SmolLM2-1.7B-Instruct-GGUF",
        filename="smollm2-1.7b-instruct-q4_k_m.gguf",
    ),
    "qwen2.5-0.5b": FormatterModelPreset(
        key="qwen2.5-0.5b",
        label="Qwen2.5 0.5B Instruct (default, fastest)",
        repo_id="Qwen/Qwen2.5-0.5B-Instruct-GGUF",
        filename="qwen2.5-0.5b-instruct-q4_k_m.gguf",
    ),
}
DEFAULT_FORMATTER_MODEL = "qwen2.5-0.5b"
DEFAULT_HF_CACHE_DIR = os.path.join(
    os.environ.get("LOCALAPPDATA", os.path.expanduser("~")),
    "voice-type",
    "llm-models",
)


@dataclasses.dataclass(frozen=True)
class ValidationDecision:
    accepted: bool
    reason: str


@dataclasses.dataclass(frozen=True)
class FormatResult:
    text: str
    used_formatter: bool
    reason: str


def formatter_applies_to_mode(mode: str) -> bool:
    return mode in SUPPORTED_FORMATTER_MODES


def resolve_system_prompt(system_prompt: str | None) -> str:
    prompt = (system_prompt or "").strip()
    return prompt or DEFAULT_FORMATTER_SYSTEM_PROMPT


def build_formatter_messages(text: str, system_prompt: str | None = None) -> list[dict[str, str]]:
    user_prompt = (
        "Clean this transcript with minimal edits.\n"
        "Keep the same meaning and almost all of the same words.\n"
        "Do not paraphrase, summarize, shorten, or make it more formal.\n"
        "Do not remove hesitation words unless they are obvious duplicate transcription mistakes.\n"
        "Only fix punctuation, capitalization, paragraph breaks, and very obvious transcript artifacts.\n"
        "Preserve names, numbers, technical terms, and uncertainty.\n"
        "Return only the cleaned transcript.\n\n"
        "Transcript:\n"
        f"{text.strip()}"
    )
    return [
        {"role": "system", "content": resolve_system_prompt(system_prompt)},
        {"role": "user", "content": user_prompt},
    ]


def _normalize_spaces(text: str) -> str:
    return " ".join(text.split())


def _tokenize_words(text: str) -> list[str]:
    return [tok.lower() for tok in _WORD_RE.findall(text)]


def _token_overlap_ratio(source: str, candidate: str) -> float:
    source_counts = Counter(_tokenize_words(source))
    candidate_counts = Counter(_tokenize_words(candidate))
    if not source_counts:
        return 1.0
    shared = sum((source_counts & candidate_counts).values())
    total = sum(source_counts.values())
    return shared / total if total else 1.0


def _removed_matches(pattern: re.Pattern[str], source: str, candidate: str) -> bool:
    source_items = {match.group(0).lower() for match in pattern.finditer(source)}
    if not source_items:
        return False
    candidate_items = {match.group(0).lower() for match in pattern.finditer(candidate)}
    return not source_items.issubset(candidate_items)


def validate_formatted_text(source: str, candidate: str) -> ValidationDecision:
    source = source.strip()
    candidate = candidate.strip()

    if not source:
        return ValidationDecision(True, "empty-input")
    if not candidate:
        return ValidationDecision(False, "empty-output")
    if source == candidate:
        return ValidationDecision(True, "unchanged")

    source_norm = _normalize_spaces(source)
    candidate_norm = _normalize_spaces(candidate)

    if _removed_matches(_NUMBER_RE, source_norm, candidate_norm):
        return ValidationDecision(False, "numbers-removed")

    if _removed_matches(_URL_RE, source_norm, candidate_norm):
        return ValidationDecision(False, "urls-removed")

    if _removed_matches(_ACRONYM_RE, source_norm, candidate_norm):
        return ValidationDecision(False, "acronyms-removed")

    length_change = abs(len(candidate_norm) - len(source_norm)) / max(1, len(source_norm))
    if length_change > MAX_LENGTH_CHANGE_RATIO:
        return ValidationDecision(False, "length-change-too-large")

    if _token_overlap_ratio(source_norm, candidate_norm) < MIN_TOKEN_OVERLAP_RATIO:
        return ValidationDecision(False, "token-overlap-too-low")

    return ValidationDecision(True, "accepted")


def format_for_injection(
    text: str,
    *,
    enabled: bool,
    mode: str,
    formatter: Callable[[str], str] | None,
    timeout_sec: float | None = None,
) -> FormatResult:
    if not text.strip():
        return FormatResult(text, False, "empty-input")
    if not enabled:
        return FormatResult(text, False, "disabled")
    if not formatter_applies_to_mode(mode):
        return FormatResult(text, False, "unsupported-mode")
    if formatter is None:
        return FormatResult(text, False, "formatter-unavailable")

    candidate: str | None = None
    if timeout_sec and timeout_sec > 0:
        result_box: dict[str, str] = {}
        error_box: dict[str, Exception] = {}

        def _worker():
            try:
                result_box["candidate"] = formatter(text)
            except Exception as exc:
                error_box["error"] = exc

        thread = threading.Thread(target=_worker, daemon=True)
        thread.start()
        thread.join(timeout_sec)
        if thread.is_alive():
            return FormatResult(text, False, "formatter-timeout")
        if "error" in error_box:
            return FormatResult(text, False, "formatter-error")
        candidate = result_box.get("candidate", "")
    else:
        try:
            candidate = formatter(text)
        except Exception:
            return FormatResult(text, False, "formatter-error")

    decision = validate_formatted_text(text, candidate)
    if not decision.accepted:
        return FormatResult(text, False, decision.reason)
    return FormatResult(candidate.strip(), True, decision.reason)


def get_formatter_preset(model_key: str) -> FormatterModelPreset:
    return FORMATTER_MODEL_PRESETS.get(model_key, FORMATTER_MODEL_PRESETS[DEFAULT_FORMATTER_MODEL])


def estimate_completion_tokens(text: str) -> int:
    words = max(1, len(_tokenize_words(text)))
    return min(256, max(64, words + 40))


def _extract_message_text(payload) -> str:
    if isinstance(payload, str):
        return payload
    if isinstance(payload, list):
        parts: list[str] = []
        for item in payload:
            if isinstance(item, dict):
                text = item.get("text")
                if isinstance(text, str):
                    parts.append(text)
        return "".join(parts)
    return ""


def _sanitize_model_output(text: str) -> str:
    cleaned = text.strip().strip("`").strip()
    lower = cleaned.lower()
    prefixes = (
        "cleaned transcript:",
        "formatted transcript:",
        "lightly formatted speech-to-text output:",
    )
    for prefix in prefixes:
        if lower.startswith(prefix):
            cleaned = cleaned[len(prefix):].strip()
            break
    if len(cleaned) >= 2 and cleaned[0] == cleaned[-1] and cleaned[0] in {'"', "'"}:
        cleaned = cleaned[1:-1].strip()
    return cleaned


class LlamaCppFormatter:
    def __init__(
        self,
        model_key: str,
        *,
        logger: Callable[[str], None] | None = None,
        cache_dir: str | None = None,
        system_prompt: str | None = None,
        n_ctx: int = 2048,
        n_threads: int | None = None,
    ):
        self.model_key = model_key
        self.preset = get_formatter_preset(model_key)
        self._logger = logger or (lambda _msg: None)
        self._cache_dir = cache_dir or DEFAULT_HF_CACHE_DIR
        self.system_prompt = resolve_system_prompt(system_prompt)
        self._n_ctx = n_ctx
        cpu_count = os.cpu_count() or 4
        self._n_threads = n_threads or max(1, cpu_count - 1)
        self._lock = threading.Lock()
        self._llm = None
        self._model_path: str | None = None

    def describe(self) -> str:
        return self.preset.label

    def warm(self):
        self._ensure_loaded()

    def _ensure_loaded(self):
        if self._llm is not None:
            return self._llm
        with self._lock:
            if self._llm is not None:
                return self._llm
            self._model_path = self._download_model()
            self._logger(f"[formatter] loading {self.preset.label} from {self._model_path}")
            from llama_cpp import Llama

            self._llm = Llama(
                model_path=self._model_path,
                n_ctx=self._n_ctx,
                n_threads=self._n_threads,
                n_batch=512,
                use_mmap=True,
                verbose=False,
            )
            return self._llm

    def _download_model(self) -> str:
        os.makedirs(self._cache_dir, exist_ok=True)
        from huggingface_hub import hf_hub_download

        model_dir = os.path.join(self._cache_dir, self.preset.key)
        os.makedirs(model_dir, exist_ok=True)
        return hf_hub_download(
            repo_id=self.preset.repo_id,
            filename=self.preset.filename,
            local_dir=model_dir,
        )

    def __call__(self, text: str) -> str:
        llm = self._ensure_loaded()
        response = llm.create_chat_completion(
            messages=build_formatter_messages(text, system_prompt=self.system_prompt),
            temperature=0.0,
            top_p=1.0,
            max_tokens=estimate_completion_tokens(text),
        )
        choices = response.get("choices") or []
        if not choices:
            return ""
        message = choices[0].get("message", {})
        return _sanitize_model_output(_extract_message_text(message.get("content")))
