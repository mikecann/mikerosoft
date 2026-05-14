"""
voice-type.py — Push-to-talk voice typing tool.

Hold RIGHT_CTRL while speaking. Partial transcription appears in the overlay
as you talk. Release to paste the final text into the active window.

A microphone icon lives in the system tray; right-click for settings and exit.

Requirements: faster-whisper, sounddevice, numpy, Pillow, pystray,
huggingface_hub, llama-cpp-python
"""

import os
import sys
import time
import math
import json
import signal
import subprocess
import threading
import queue
import tkinter as tk
from tkinter import messagebox
from tkinter import scrolledtext
from tkinter import ttk

os.environ.setdefault("HF_HUB_DISABLE_SYMLINKS_WARNING", "1")

# ---------------------------------------------------------------------------
# Platform abstraction — all OS-specific behaviour lives in platform_*.py
# ---------------------------------------------------------------------------

if sys.platform == "win32":
    import platform_win as platform  # type: ignore[import]
elif sys.platform == "darwin":
    import platform_mac as platform  # type: ignore[import]
else:
    raise RuntimeError(f"Unsupported platform: {sys.platform}")

if sys.platform == "darwin":
    from appkit_overlay import AppKitOverlaySurface

platform.setup_dll_paths()

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

_LOG_PATH    = os.path.join(os.path.dirname(os.path.abspath(__file__)), "voice-type.log")
_SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
_CONTROL_SOCKET_PATH = os.path.join(_SCRIPT_DIR, "voice-type-control.sock")
_INSTANCE_LOCK_PATH = os.path.join(_SCRIPT_DIR, "voice-type.instance.lock")
_HEARTBEAT_PATH = os.path.join(_SCRIPT_DIR, "voice-type.heartbeat")
_HEARTBEAT_INTERVAL = 0.5       # how often the hotkey loop refreshes the heartbeat
_HEARTBEAT_STALE_SECONDS = 10   # older than this => the running instance is wedged
_LOG_MAX_MB  = 1       # rotate when log exceeds this size
_LOG_KEEP    = 200     # lines to keep after rotation


_instance_lock_file = None


def _write_heartbeat() -> None:
    """Refresh the heartbeat file's mtime so other instances can tell we're alive."""
    try:
        with open(_HEARTBEAT_PATH, "w", encoding="utf-8") as f:
            f.write(str(time.time()))
    except Exception:
        pass


def _heartbeat_age() -> float | None:
    """Seconds since the running instance last refreshed its heartbeat, or None."""
    try:
        return time.time() - os.path.getmtime(_HEARTBEAT_PATH)
    except OSError:
        return None


def _flock_nb(lock_file) -> bool:
    """Try to grab the instance lock without blocking. True on success."""
    if sys.platform == "win32":
        import msvcrt
        lock_file.seek(0)
        try:
            msvcrt.locking(lock_file.fileno(), msvcrt.LK_NBLCK, 1)
            return True
        except OSError:
            return False
    import fcntl
    try:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except OSError:
        return False


def _read_lock_pid(lock_file) -> int | None:
    try:
        lock_file.seek(0)
        return int((lock_file.read() or "").strip())
    except (ValueError, OSError):
        return None


def _kill_wedged_instance(pid: int) -> None:
    """SIGTERM, then SIGKILL if it lingers, a wedged instance so we can take over."""
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    except OSError:
        pass
    for _ in range(20):  # up to ~2s for a graceful exit
        time.sleep(0.1)
        try:
            os.kill(pid, 0)
        except OSError:
            return  # gone
    try:
        os.kill(pid, signal.SIGKILL)
        time.sleep(0.3)
    except OSError:
        pass


def _acquire_single_instance_lock() -> bool:
    global _instance_lock_file
    lock_file = open(_INSTANCE_LOCK_PATH, "a+", encoding="utf-8")
    try:
        if not _flock_nb(lock_file):
            # Another instance holds the lock. If its heartbeat is fresh it is
            # healthy and we exit as a duplicate. If the heartbeat is stale (or
            # absent) the running instance is wedged -- e.g. a CoreAudio
            # deadlock -- so we kill it and take over.
            age = _heartbeat_age()
            healthy = age is not None and age < _HEARTBEAT_STALE_SECONDS
            if healthy or sys.platform == "win32":
                lock_file.close()
                return False
            pid = _read_lock_pid(lock_file)
            print(
                f"voice-type: existing instance (pid {pid}) looks wedged "
                f"(heartbeat age {age}); killing it and taking over.",
                flush=True,
            )
            if pid and pid != os.getpid():
                _kill_wedged_instance(pid)
            for _ in range(20):  # wait for the dead instance to release the lock
                if _flock_nb(lock_file):
                    break
                time.sleep(0.1)
            else:
                lock_file.close()
                return False
        lock_file.seek(0)
        lock_file.truncate()
        lock_file.write(str(os.getpid()))
        lock_file.flush()
        _instance_lock_file = lock_file
        _write_heartbeat()
        return True
    except Exception:
        lock_file.close()
        raise


if not _acquire_single_instance_lock():
    print("voice-type is already running; exiting duplicate instance.", flush=True)
    sys.exit(0)


def _rotate_log():
    """On startup: if log > _LOG_MAX_MB, keep only the last _LOG_KEEP lines."""
    try:
        if not os.path.exists(_LOG_PATH):
            return
        if os.path.getsize(_LOG_PATH) < _LOG_MAX_MB * 1024 * 1024:
            return
        with open(_LOG_PATH, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
        kept = lines[-_LOG_KEEP:]
        with open(_LOG_PATH, "w", encoding="utf-8") as f:
            f.write(f"[log rotated — kept last {_LOG_KEEP} of {len(lines)} lines]\n")
            f.writelines(kept)
    except Exception:
        pass  # never crash on log housekeeping

_rotate_log()
_log_lock   = threading.Lock()
_log_file   = open(_LOG_PATH, "a", encoding="utf-8", buffering=1)


def log(msg: str):
    ts = time.strftime("%H:%M:%S")
    line = f"{ts}  {msg}"
    with _log_lock:
        _log_file.write(line + "\n")
        _log_file.flush()
    print(line, flush=True)


log(f"=== voice-type started === log: {_LOG_PATH}")

import numpy as np
import sounddevice as sd
from faster_whisper import WhisperModel
from runtime_policy import should_keep_mic_stream_open_local
from speech_backends import MlxWhisperModel, resolve_local_mlx_repo
from text_formatter import (
    DEFAULT_FORMATTER_MODEL,
    DEFAULT_FORMATTER_SYSTEM_PROMPT,
    FORMATTER_MODEL_PRESETS,
    LlamaCppFormatter,
    format_for_injection as format_text_for_injection,
    resolve_system_prompt,
)
from preview_format import wrap_preview
from voice_type_control import ControlServer

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

POLL_INTERVAL    = 0.01   # key-state poll rate (100 Hz)
MAX_RECORDING_SECONDS = 120  # safety cap: force-stop if the hotkey appears stuck down
STREAM_CLOSE_TIMEOUT  = 2.0  # give up on a stream stop/close if CoreAudio deadlocks
STREAM_INTERVAL  = 0.5    # seconds between streaming preview passes
STREAM_MIN_AUDIO = 0.8    # don't start streaming until this many seconds recorded
PRECOMP_MIN_AUDIO = 2.5   # only precompute once enough audio has accumulated
PRECOMP_MIN_DELTA = 0.8   # minimum new audio before launching another pass
PRECOMP_OVERLAP = 1.2     # seconds of overlap to stitch base+tail safely
PRECOMP_IDLE_SLEEP = 0.08 # small backoff while waiting for enough new audio
PRECOMP_STOP_WAIT = 0.75  # wait briefly for in-flight pass to finish on key-up
FORMATTER_TIMEOUT = 6.0   # soft timeout for local text cleanup

# Final transcription model (accurate):
#   CPU → "small.en"        ~0.5–1.5s depending on clip length
#   GPU → "large-v3-turbo"  ~0.2s on CUDA
GPU_MODEL    = "large-v3-turbo"
CPU_MODEL    = "small.en"

# Streaming preview model (speed over accuracy — visual feedback only):
# tiny.en runs in ~0.1s on CPU so it never meaningfully blocks the final pass.
STREAM_MODEL = "tiny.en"

SAMPLE_RATE  = 16000
CHANNELS     = 1
DTYPE        = "float32"
DEVICE       = None       # None = system default mic
COMPUTE_TYPE = "float16"  # float16 on GPU; overridden to int8 on CPU

# Models available in the tray settings menu.
# Final model: accuracy matters most; stream model: speed matters most.
FINAL_MODEL_OPTIONS  = ["tiny.en", "base.en", "small.en", "medium.en",
                        "large-v2", "large-v3", "large-v3-turbo", "parakeet-tdt-0.6b"]
STREAM_MODEL_OPTIONS = ["tiny.en", "base.en", "small.en"]

MODEL_LABELS = {
    "tiny.en":          "Whisper: tiny",
    "base.en":          "Whisper: base",
    "small.en":         "Whisper: small",
    "medium.en":        "Whisper: medium",
    "large-v2":         "Whisper: large-v2",
    "large-v3":         "Whisper: large-v3",
    "large-v3-turbo":   "Whisper: large-v3-turbo",
    "parakeet-tdt-0.6b": "NVIDIA Parakeet: TDT 0.6b",
}
OUTPUT_MODE_OPTIONS  = ["final_only", "hybrid", "stabilized", "precompute"]
FORMATTER_MODEL_OPTIONS = list(FORMATTER_MODEL_PRESETS.keys())

# ---------------------------------------------------------------------------
# Settings (persisted to settings.json beside the script)
# ---------------------------------------------------------------------------

_SETTINGS_PATH = os.path.join(_SCRIPT_DIR, "settings.json")
_settings: dict = {}


def _load_settings():
    """Load settings.json, filling missing keys with hardware-appropriate defaults."""
    global _settings
    if os.path.exists(_SETTINGS_PATH):
        try:
            with open(_SETTINGS_PATH, "r", encoding="utf-8") as f:
                _settings = json.load(f)
        except Exception as e:
            log(f"Settings load failed: {e}; using defaults.")
            _settings = {}
    # Defaults are resolved after CUDA detection so the right model is chosen.
    cuda = platform.cuda_available()
    _settings.setdefault("final_model",  GPU_MODEL if cuda else CPU_MODEL)
    _settings.setdefault("stream_model", GPU_MODEL if cuda else STREAM_MODEL)
    _settings.setdefault("output_mode",  "final_only")
    _settings.setdefault("formatter_enabled", False)
    _settings.setdefault("formatter_model", DEFAULT_FORMATTER_MODEL)
    _settings.setdefault("formatter_system_prompt", DEFAULT_FORMATTER_SYSTEM_PROMPT)
    if _settings.get("formatter_model") not in FORMATTER_MODEL_PRESETS:
        _settings["formatter_model"] = DEFAULT_FORMATTER_MODEL
    # User-editable word/phrase corrections applied after every transcription.
    # Keys are what the model says (case-insensitive), values are what to inject.
    # Example: "Q DA" -> "CUDA", "congress" -> "Convex"
    _settings.setdefault("corrections", {
        "Q DA": "CUDA",
        "Kuda": "CUDA",
    })
    _save_settings()


def _save_settings():
    try:
        with open(_SETTINGS_PATH, "w", encoding="utf-8") as f:
            json.dump(_settings, f, indent=2)
    except Exception as e:
        log(f"Settings save failed: {e}")


# Windows-only: path to the VBS silent launcher (used by startup registration).
_VBS_PATH = os.path.join(_SCRIPT_DIR, "voice-type.vbs")

_OUTPUT_MODE_LABELS = {
    "final_only": "Final Only (quality)",
    "hybrid": "Hybrid (live overlay)",
    "stabilized": "Stabilized (faster output)",
    "precompute": "Precompute (faster finalize)",
}


# ---------------------------------------------------------------------------
# Models
#
# Two separate instances so streaming never contends with final transcription:
#   _stream_model  tiny.en   CPU int8  ~0.1s/pass  — live preview only
#   _model         small.en  CPU int8  ~0.5–1.5s   — accurate final result
#                  (large-v3-turbo on CUDA for both)
# ---------------------------------------------------------------------------

import re

# Parakeet is very literal and transcribes filler words exactly.
# Strip the most common English speech disfluencies from Parakeet output.
_FILLER_RE = re.compile(
    r'\b(uh+|um+|er+|ah+|hmm+|hm+|mhm|erm)\b[,.]?',
    re.IGNORECASE,
)

def _clean_parakeet(text: str) -> str:
    cleaned = _FILLER_RE.sub('', text)
    return ' '.join(cleaned.split())


def _apply_corrections(text: str) -> str:
    """Apply user-defined word/phrase corrections from settings.json.

    Matches are case-insensitive whole-word. Replacements preserve the
    exact casing from the corrections dict value.
    """
    corrections: dict = _settings.get("corrections", {})
    for wrong, right in corrections.items():
        pattern = re.compile(r'(?<!\w)' + re.escape(wrong) + r'(?!\w)', re.IGNORECASE)
        text = pattern.sub(right, text)
    return text


class ParakeetSegment:
    def __init__(self, text):
        self.text = text

class ParakeetInfo:
    language = "en"
    language_probability = 1.0

# Map of short names (used in settings/menu) to HuggingFace repo IDs.
# csukuangfj is the primary sherpa-onnx developer — most reliable exports.
PARAKEET_REPOS = {
    "parakeet-tdt-0.6b": "csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
}

class ParakeetWrapper:
    def __init__(self, repo_id: str):
        from huggingface_hub import snapshot_download
        import sherpa_onnx

        log(f"Downloading/verifying Parakeet model {repo_id}...")
        local_dir = snapshot_download(repo_id=repo_id)

        self.recognizer = sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=os.path.join(local_dir, "encoder.int8.onnx"),
            decoder=os.path.join(local_dir, "decoder.int8.onnx"),
            joiner=os.path.join(local_dir, "joiner.int8.onnx"),
            tokens=os.path.join(local_dir, "tokens.txt"),
            num_threads=4,
            sample_rate=SAMPLE_RATE,
            feature_dim=80,
            model_type="nemo_transducer"
        )

    def transcribe(self, audio, **kwargs):
        stream = self.recognizer.create_stream()
        stream.accept_waveform(SAMPLE_RATE, audio)
        self.recognizer.decode_stream(stream)
        text = _clean_parakeet(stream.result.text)

        segments = [ParakeetSegment(text)] if text else []
        return segments, ParakeetInfo()


_model = None
_model_lock = threading.Lock()


def _load_faster_whisper_model(name: str):
    cuda = platform.cuda_available()
    device = "cuda" if cuda else "cpu"
    ct = COMPUTE_TYPE if cuda else "int8"
    log(f"Loading final model {name!r} on {device} ({ct})...")
    return WhisperModel(name, device=device, compute_type=ct)


def get_model():
    global _model
    if _model is None:
        with _model_lock:
            if _model is None:
                name = _settings.get("final_model", CPU_MODEL)
                if name in PARAKEET_REPOS:
                    log(f"Loading final model {name!r} (sherpa-onnx)...")
                    repo_id = PARAKEET_REPOS[name]
                    _model = ParakeetWrapper(repo_id)
                    log("Final model ready.")
                    return _model

                mlx_repo = resolve_local_mlx_repo(model_name=name)
                if mlx_repo:
                    try:
                        log(f"Loading final model {name!r} on mlx ({mlx_repo})...")
                        mlx_model = MlxWhisperModel(repo_id=mlx_repo)
                        mlx_model.warm()
                        _model = mlx_model
                        log("Final model ready.")
                        return _model
                    except Exception as e:
                        log(f"MLX load failed for {name!r}: {e}. Falling back to faster-whisper.")

                _model = _load_faster_whisper_model(name)
                log("Final model ready.")
    return _model


_stream_model: WhisperModel | None = None
_stream_model_lock = threading.Lock()


def get_stream_model() -> WhisperModel | None:
    """Returns the streaming preview model, or None if not yet loaded."""
    return _stream_model


def _load_stream_model():
    """Load the stream model in the background. Waits for the final model first
    to avoid competing for CPU during initial warm-up."""
    global _stream_model
    get_model()   # ensure final model finishes first
    with _stream_model_lock:
        if _stream_model is None:
            cuda   = platform.cuda_available()
            name   = _settings.get("stream_model", STREAM_MODEL)
            device = "cuda" if cuda else "cpu"
            ct     = COMPUTE_TYPE if cuda else "int8"
            log(f"Loading stream model {name!r} on {device} ({ct})...")
            _stream_model = WhisperModel(name, device=device, compute_type=ct)
            log("Stream model ready.")


_text_formatter: LlamaCppFormatter | None = None
_text_formatter_lock = threading.Lock()


def get_text_formatter() -> LlamaCppFormatter | None:
    global _text_formatter
    if not _settings.get("formatter_enabled", False):
        return None
    model_key = _settings.get("formatter_model", DEFAULT_FORMATTER_MODEL)
    system_prompt = resolve_system_prompt(_settings.get("formatter_system_prompt"))
    if model_key not in FORMATTER_MODEL_PRESETS:
        model_key = DEFAULT_FORMATTER_MODEL
    needs_reload = (
        _text_formatter is None
        or _text_formatter.model_key != model_key
        or _text_formatter.system_prompt != system_prompt
    )
    if needs_reload:
        with _text_formatter_lock:
            needs_reload = (
                _text_formatter is None
                or _text_formatter.model_key != model_key
                or _text_formatter.system_prompt != system_prompt
            )
            if needs_reload:
                try:
                    _text_formatter = LlamaCppFormatter(
                        model_key,
                        logger=log,
                        system_prompt=system_prompt,
                    )
                    _text_formatter.warm()
                    log(f"Formatter model ready: {_text_formatter.describe()}")
                except Exception:
                    _text_formatter = None
                    raise
    return _text_formatter


def _set_final_model(name: str):
    """Switch the final transcription model; reloads it in the background."""
    global _model
    if _settings.get("final_model") == name:
        return
    log(f"Final model switching to {name!r}...")
    _settings["final_model"] = name
    _save_settings()
    with _model_lock:
        _model = None
    threading.Thread(target=get_model, daemon=True).start()


def _set_stream_model(name: str):
    """Switch the streaming preview model; reloads it in the background."""
    global _stream_model
    if _settings.get("stream_model") == name:
        return
    log(f"Stream model switching to {name!r}...")
    _settings["stream_model"] = name
    _save_settings()
    with _stream_model_lock:
        _stream_model = None
    threading.Thread(target=_load_stream_model, daemon=True).start()


def _set_output_mode(name: str):
    """Switch the finalize output mode; persists immediately."""
    if _settings.get("output_mode") == name:
        return
    log(f"Output mode switching to {name!r}...")
    _settings["output_mode"] = name
    _save_settings()


def _set_formatter_enabled(enabled: bool):
    enabled = bool(enabled)
    if bool(_settings.get("formatter_enabled", False)) == enabled:
        return
    log(f"Formatter {'enabled' if enabled else 'disabled'}.")
    _settings["formatter_enabled"] = enabled
    _save_settings()
    if enabled:
        threading.Thread(target=get_text_formatter, daemon=True).start()


def _set_formatter_model(name: str):
    global _text_formatter
    if name not in FORMATTER_MODEL_PRESETS:
        return
    if _settings.get("formatter_model") == name:
        return
    log(f"Formatter model switching to {name!r}...")
    _settings["formatter_model"] = name
    _save_settings()
    with _text_formatter_lock:
        _text_formatter = None
    if _settings.get("formatter_enabled", False):
        threading.Thread(target=get_text_formatter, daemon=True).start()


def _set_formatter_system_prompt(prompt: str):
    global _text_formatter
    prompt = resolve_system_prompt(prompt)
    if _settings.get("formatter_system_prompt") == prompt:
        return
    log("Formatter system prompt updated.")
    _settings["formatter_system_prompt"] = prompt
    _save_settings()
    with _text_formatter_lock:
        _text_formatter = None
    if _settings.get("formatter_enabled", False):
        threading.Thread(target=get_text_formatter, daemon=True).start()


def _effective_output_mode() -> str:
    """Return the active output mode, forcing final_only for Parakeet.

    Parakeet returns a single segment for the whole recording, so hybrid /
    stabilized / precompute provide no benefit and would behave oddly.
    """
    if _settings.get("final_model", "") in PARAKEET_REPOS:
        return "final_only"
    return _settings.get("output_mode", "final_only")


def _maybe_format_final_text(text: str, mode: str) -> str:
    enabled = bool(_settings.get("formatter_enabled", False))
    started = time.perf_counter()
    formatter = None
    if enabled:
        try:
            formatter = get_text_formatter()
        except Exception as e:
            log(f"Formatter unavailable: {e}")
            formatter = None
    result = format_text_for_injection(
        text,
        enabled=enabled,
        mode=mode,
        formatter=formatter,
        timeout_sec=FORMATTER_TIMEOUT,
    )
    elapsed_ms = (time.perf_counter() - started) * 1000.0
    if enabled:
        if result.used_formatter:
            log(f"Formatter accepted [{mode}] in {elapsed_ms:.0f} ms: {result.reason}")
        else:
            log(f"Formatter skipped [{mode}] in {elapsed_ms:.0f} ms: {result.reason}")
    return result.text


# ---------------------------------------------------------------------------
# Tray icon drawing (Pillow)
# ---------------------------------------------------------------------------

_TRAY_COLORS = {
    "idle":       (72,  72,  82),
    "recording":  (192, 57,  43),
    "processing": (211, 84,   0),
    "disabled":   (38,  38,  42),
}

_TRAY_LABELS = {
    "idle":       "Voice Type — Ready",
    "recording":  "Voice Type — Recording…",
    "processing": "Voice Type — Transcribing…",
    "disabled":   "Voice Type — Disabled",
}


def _make_tray_icon(state: str):
    from PIL import Image, ImageDraw

    fg   = _TRAY_COLORS.get(state, _TRAY_COLORS["idle"])
    size = 64
    img  = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d    = ImageDraw.Draw(img)
    cx   = size // 2

    # Coloured background circle
    d.ellipse([1, 1, size - 2, size - 2], fill=(*fg, 255))

    # Microphone body (white capsule)
    wh = (255, 255, 255, 230)
    bw, bh, radius = 16, 22, 8
    bx0, by0 = cx - bw // 2, 9
    bx1, by1 = cx + bw // 2, by0 + bh
    try:
        d.rounded_rectangle([bx0, by0, bx1, by1], radius=radius, fill=wh)
    except AttributeError:
        # Pillow < 8.2 fallback
        d.rectangle([bx0 + radius, by0, bx1 - radius, by1], fill=wh)
        d.rectangle([bx0, by0 + radius, bx1, by1 - radius], fill=wh)
        for ex, ey in [(bx0, by0), (bx1 - 2*radius, by0),
                       (bx0, by1 - 2*radius), (bx1 - 2*radius, by1 - 2*radius)]:
            d.ellipse([ex, ey, ex + 2*radius, ey + 2*radius], fill=wh)

    # Stand arc
    d.arc([cx - 15, by1 - 3, cx + 15, by1 + 13], start=0, end=180, fill=wh, width=3)
    # Stem
    d.line([cx, by1 + 10, cx, by1 + 15], fill=wh, width=3)
    # Base
    d.line([cx - 9, by1 + 15, cx + 9, by1 + 15], fill=wh, width=3)

    return img


# ---------------------------------------------------------------------------
# System tray icon (pystray — runs in its own background thread)
# ---------------------------------------------------------------------------

class TrayIcon:
    def __init__(self, overlay: "Overlay"):
        self._overlay = overlay
        self.enabled  = True         # read/written by hotkey thread & tray thread
        self._icon    = None

    def start(self):
        import pystray

        def _make_final_action(name):
            return lambda: _set_final_model(name)

        def _make_final_check(name):
            return lambda item: _settings.get("final_model") == name

        def _make_stream_action(name):
            return lambda: _set_stream_model(name)

        def _make_stream_check(name):
            return lambda item: _settings.get("stream_model") == name

        def _final_model_items():
            return [
                pystray.MenuItem(
                    MODEL_LABELS.get(m, m),
                    _make_final_action(m),
                    checked=_make_final_check(m),
                    radio=True,
                )
                for m in FINAL_MODEL_OPTIONS
            ]

        def _stream_model_items():
            return [
                pystray.MenuItem(
                    MODEL_LABELS.get(m, m),
                    _make_stream_action(m),
                    checked=_make_stream_check(m),
                    radio=True,
                )
                for m in STREAM_MODEL_OPTIONS
            ]

        _OUTPUT_MODE_LABELS = {
            "final_only":  "Final Only (quality)",
            "hybrid":      "Hybrid (live overlay)",
            "stabilized":  "Stabilized (faster output)",
            "precompute":  "Precompute (faster finalize)",
        }

        def _make_output_mode_action(name):
            return lambda: _set_output_mode(name)

        def _make_output_mode_check(name):
            return lambda item: _settings.get("output_mode") == name

        def _output_mode_items():
            return [
                pystray.MenuItem(
                    _OUTPUT_MODE_LABELS.get(m, m),
                    _make_output_mode_action(m),
                    checked=_make_output_mode_check(m),
                    radio=True,
                )
                for m in OUTPUT_MODE_OPTIONS
            ]

        def _make_formatter_model_action(name):
            return lambda: _set_formatter_model(name)

        def _make_formatter_model_check(name):
            return lambda item: _settings.get("formatter_model") == name

        def _formatter_model_items():
            return [
                pystray.MenuItem(
                    FORMATTER_MODEL_PRESETS[m].label,
                    _make_formatter_model_action(m),
                    checked=_make_formatter_model_check(m),
                    radio=True,
                )
                for m in FORMATTER_MODEL_OPTIONS
            ]

        def _formatter_section_items():
            items = []
            if _settings.get("formatter_enabled", False):
                items.append(pystray.MenuItem("Model", pystray.Menu(lambda: _formatter_model_items())))
            items.append(pystray.MenuItem("Edit System Prompt...", self._edit_formatter_prompt))
            items.append(pystray.MenuItem("Reset System Prompt", self._reset_formatter_prompt))
            return items

        def _menu_items():
            items = [
                pystray.MenuItem("Voice Type", None, enabled=False),
                pystray.Menu.SEPARATOR,
                pystray.MenuItem(
                    "Enabled",
                    self._toggle_enabled,
                    checked=lambda item: self.enabled,
                ),
                pystray.MenuItem(
                    "Formatter Enabled",
                    lambda: _set_formatter_enabled(not _settings.get("formatter_enabled", False)),
                    checked=lambda item: bool(_settings.get("formatter_enabled", False)),
                ),
                pystray.MenuItem("Open Log", self._open_log),
                pystray.MenuItem(
                    "Run on Startup",
                    self._toggle_startup,
                    checked=lambda item: platform.startup_enabled(_VBS_PATH),
                ),
                pystray.Menu.SEPARATOR,
                pystray.MenuItem("Final Model", pystray.Menu(lambda: _final_model_items())),
                pystray.MenuItem("Preview Model", pystray.Menu(lambda: _stream_model_items())),
                pystray.MenuItem("Output Mode", pystray.Menu(lambda: _output_mode_items())),
            ]
            if _settings.get("formatter_enabled", False):
                items.append(pystray.MenuItem("Formatter", pystray.Menu(lambda: _formatter_section_items())))
            items.extend([
                pystray.Menu.SEPARATOR,
                pystray.MenuItem("Exit", self._on_exit),
            ])
            return items

        menu = pystray.Menu(lambda: _menu_items())
        icon_kwargs = {}
        if sys.platform == "darwin":
            from AppKit import NSApp  # type: ignore[import]
            icon_kwargs["darwin_nsapplication"] = NSApp

        self._icon = pystray.Icon(
            "voice-type",
            _make_tray_icon("idle"),
            _TRAY_LABELS["idle"],
            **icon_kwargs,
        )

        def _icon_setup(icon):
            icon.visible = True
            icon.menu = menu
            icon.update_menu()
            if sys.platform == "darwin":
                button = icon._status_item.button()
                button.setTarget_(None)
                button.setAction_(None)
            log("Tray menu attached.")

        self._icon.run_detached(setup=_icon_setup)
        log("Tray icon started.")

    def set_state(self, state: str):
        """Thread-safe: update icon colour and tooltip to reflect current state."""
        if self._icon is None:
            return
        effective = "disabled" if not self.enabled else state
        self._icon.icon  = _make_tray_icon(effective)
        self._icon.title = _TRAY_LABELS.get(effective, "Voice Type")

    # ---- Menu callbacks (called on pystray's thread) ----

    def _toggle_enabled(self, icon, item):
        self.enabled = not self.enabled
        log(f"Voice Type {'enabled' if self.enabled else 'disabled'} via tray.")
        self.set_state("idle")

    def _open_log(self, icon, item):
        platform.open_log(_LOG_PATH)

    def _toggle_startup(self, icon, item):
        platform.set_startup(not platform.startup_enabled(_VBS_PATH), _VBS_PATH, log)

    def _edit_formatter_prompt(self, icon=None, item=None):
        self._overlay.edit_text(
            title="Edit Formatter System Prompt",
            initial_text=resolve_system_prompt(_settings.get("formatter_system_prompt")),
            on_save=_set_formatter_system_prompt,
            reset_text=DEFAULT_FORMATTER_SYSTEM_PROMPT,
        )

    def _reset_formatter_prompt(self, icon=None, item=None):
        _set_formatter_system_prompt(DEFAULT_FORMATTER_SYSTEM_PROMPT)

    def _on_exit(self, icon, item):
        log("Exit requested via tray.")
        icon.stop()
        self._overlay.quit()   # ask tkinter main loop to exit cleanly


class MacTrayIcon:
    def __init__(self, overlay: "Overlay"):
        self._overlay = overlay
        self.enabled = True
        self._state = "idle"

    def start(self):
        log("macOS settings are available by clicking the overlay.")

    def set_state(self, state: str):
        effective = "disabled" if not self.enabled else state
        self._state = effective

    def _on_exit(self, icon, item):
        log("Exit requested via tray.")
        self._overlay.quit()


def _build_control_state(tray) -> dict:
    return {
        "enabled": tray.enabled,
        "ui_state": getattr(tray, "_state", "idle"),
        "final_model": _settings.get("final_model"),
        "stream_model": _settings.get("stream_model"),
        "output_mode": _settings.get("output_mode"),
        "formatter_enabled": bool(_settings.get("formatter_enabled", False)),
        "formatter_model": _settings.get("formatter_model"),
        "startup_enabled": platform.startup_enabled(_VBS_PATH),
        "log_path": _LOG_PATH,
        "final_model_options": FINAL_MODEL_OPTIONS,
        "stream_model_options": STREAM_MODEL_OPTIONS,
        "output_mode_options": OUTPUT_MODE_OPTIONS,
        "formatter_model_options": FORMATTER_MODEL_OPTIONS,
        "model_labels": MODEL_LABELS,
        "output_mode_labels": _OUTPUT_MODE_LABELS,
        "formatter_model_labels": {
            name: FORMATTER_MODEL_PRESETS[name].label
            for name in FORMATTER_MODEL_OPTIONS
        },
    }


def _apply_settings_changes(*, tray, updates: dict) -> None:
    enabled = bool(updates.get("enabled", True))
    if tray.enabled != enabled:
        tray.enabled = enabled
        log(f"Voice Type {'enabled' if enabled else 'disabled'} via settings.")
        tray.set_state("idle")

    startup_enabled = bool(updates.get("startup_enabled", False))
    if platform.startup_enabled(_VBS_PATH) != startup_enabled:
        platform.set_startup(startup_enabled, _VBS_PATH, log)

    _set_final_model(str(updates.get("final_model", _settings.get("final_model"))))
    _set_stream_model(str(updates.get("stream_model", _settings.get("stream_model"))))
    _set_output_mode(str(updates.get("output_mode", _settings.get("output_mode"))))
    _set_formatter_enabled(bool(updates.get("formatter_enabled", _settings.get("formatter_enabled", False))))
    _set_formatter_model(str(updates.get("formatter_model", _settings.get("formatter_model"))))


def _restart_app() -> None:
    """Last-resort restart: spawn the relauncher detached, so it survives this
    process being killed, then kill/relaunch voice-type. Used by the settings
    window's Restart button to recover a wedged overlay."""
    log("Restart requested from settings window.")
    if sys.platform == "win32":
        script = os.path.join(_SCRIPT_DIR, "restart.bat")
        subprocess.Popen(
            ["cmd", "/c", script], cwd=_SCRIPT_DIR,
            creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
            | getattr(subprocess, "DETACHED_PROCESS", 0),
        )
    else:
        script = os.path.join(_SCRIPT_DIR, "voice-type-mac.sh")
        subprocess.Popen(
            ["bash", script], cwd=_SCRIPT_DIR, start_new_session=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )


def _show_settings_dialog(overlay: "Overlay", tray) -> None:
    overlay.edit_settings(
        state=_build_control_state(tray),
        on_save=lambda updates: _apply_settings_changes(tray=tray, updates=updates),
        on_open_log=lambda: platform.open_log(_LOG_PATH),
        on_restart=_restart_app,
        defer_until_hidden=False,
    )


def _queue_settings_dialog_after_hide(overlay: "Overlay", tray) -> None:
    overlay.edit_settings(
        state=_build_control_state(tray),
        on_save=lambda updates: _apply_settings_changes(tray=tray, updates=updates),
        on_open_log=lambda: platform.open_log(_LOG_PATH),
        on_restart=_restart_app,
        defer_until_hidden=True,
    )


def _make_control_server(tray, overlay: "Overlay") -> ControlServer:
    def _toggle_enabled(_request):
        tray.enabled = not tray.enabled
        log(f"Voice Type {'enabled' if tray.enabled else 'disabled'} via menu helper.")
        tray.set_state("idle")

    def _set_final(request):
        name = request.get("value")
        if name not in FINAL_MODEL_OPTIONS:
            raise ValueError(f"Unsupported final model: {name!r}")
        _set_final_model(name)

    def _set_stream(request):
        name = request.get("value")
        if name not in STREAM_MODEL_OPTIONS:
            raise ValueError(f"Unsupported preview model: {name!r}")
        _set_stream_model(name)

    def _set_output(request):
        name = request.get("value")
        if name not in OUTPUT_MODE_OPTIONS:
            raise ValueError(f"Unsupported output mode: {name!r}")
        _set_output_mode(name)

    def _set_formatter_enabled_command(request):
        enabled = bool(request.get("value"))
        _set_formatter_enabled(enabled)

    def _set_formatter_model_command(request):
        name = request.get("value")
        if name not in FORMATTER_MODEL_OPTIONS:
            raise ValueError(f"Unsupported formatter model: {name!r}")
        _set_formatter_model(name)

    def _open_log(_request):
        platform.open_log(_LOG_PATH)

    def _toggle_startup(_request):
        platform.set_startup(not platform.startup_enabled(_VBS_PATH), _VBS_PATH, log)

    def _quit(_request):
        log("Exit requested via menu helper.")
        overlay.quit()

    def _show_settings(_request):
        _show_settings_dialog(overlay, tray)

    return ControlServer(
        socket_path=_CONTROL_SOCKET_PATH,
        get_state=lambda: _build_control_state(tray),
        commands={
            "toggle_enabled": _toggle_enabled,
            "set_final_model": _set_final,
            "set_stream_model": _set_stream,
            "set_output_mode": _set_output,
            "set_formatter_enabled": _set_formatter_enabled_command,
            "set_formatter_model": _set_formatter_model_command,
            "open_log": _open_log,
            "toggle_startup": _toggle_startup,
            "show_settings": _show_settings,
            "quit": _quit,
        },
        log=log,
    )


# ---------------------------------------------------------------------------
# Overlay window — must be created and run on the MAIN thread (Windows/Tk rule)
# ---------------------------------------------------------------------------

# Colours
_OVL_BG      = "#1C1C1E"   # dark charcoal background
_COL_REC     = "#FF453A"   # iOS-style red
_COL_PROC    = "#FF9F0A"   # iOS-style amber
_COL_TEXT    = "#EBEBF5"   # near-white
_COL_PREVIEW = "#8E8E93"   # grey for partial text

# Waveform bar geometry
_N_BARS    = 7
_BAR_W     = 4
_BAR_GAP   = 3
_CANVAS_W  = _N_BARS * _BAR_W + (_N_BARS - 1) * _BAR_GAP  # 46 px
_CANVAS_H  = 28
_BAR_MAX_H = 20
_BAR_MIN_H = 3

def _wrap_preview(text: str) -> str:
    return wrap_preview(text)


class Overlay:
    def __init__(self, get_level):
        """
        get_level: callable() -> float  — returns current mic RMS (0.0–1.0).
        Used to drive the waveform animation while recording.
        """
        self._get_level = get_level
        self._state     = "hidden"   # "hidden" | "rec" | "processing"
        self._bar_h     = [float(_BAR_MIN_H)] * _N_BARS
        self._monitor   = None       # cached work-area tuple for reposition
        self._on_click  = None

        self._root = tk.Tk()
        self._root.withdraw()
        self._is_native_surface = sys.platform == "darwin"
        self._native_surface = AppKitOverlaySurface() if self._is_native_surface else None
        self._bar_ids = []

        if not self._is_native_surface:
            self._root.overrideredirect(True)
            self._root.attributes("-topmost", True)
            self._root.configure(bg=_OVL_BG)
            self._root.resizable(False, False)

            self._accent = tk.Frame(self._root, width=4, bg=_COL_REC)
            self._accent.pack(side="left", fill="y")

            body = tk.Frame(self._root, bg=_OVL_BG, padx=10, pady=8)
            body.pack(side="left", fill="both", expand=True)

            top = tk.Frame(body, bg=_OVL_BG)
            top.pack(fill="x")

            self._dot = tk.Label(top, text="●", fg=_COL_REC, bg=_OVL_BG,
                                 font=("Segoe UI", 8))
            self._dot.pack(side="left")

            self._label = tk.Label(top, text=" REC", fg=_COL_TEXT, bg=_OVL_BG,
                                   font=("Segoe UI", 10, "bold"))
            self._label.pack(side="left")

            self._canvas = tk.Canvas(top, width=_CANVAS_W + 4, height=_CANVAS_H,
                                     bg=_OVL_BG, highlightthickness=0)
            self._canvas.pack(side="left", padx=(12, 0))

            for i in range(_N_BARS):
                x0 = 2 + i * (_BAR_W + _BAR_GAP)
                x1 = x0 + _BAR_W
                y1 = _CANVAS_H - 2
                y0 = y1 - _BAR_MIN_H
                rid = self._canvas.create_rectangle(x0, y0, x1, y1,
                                                    fill=_COL_REC, outline="")
                self._bar_ids.append(rid)

            self._preview = tk.Label(body, text="", fg=_COL_PREVIEW, bg=_OVL_BG,
                                     font=("Segoe UI", 12), anchor="w",
                                     justify="left", wraplength=360,
                                     pady=2)

            platform.apply_overlay_no_activate(self._root)
            for widget in (
                self._root, self._accent, body, top, self._dot, self._label,
                self._canvas, self._preview,
            ):
                widget.bind("<Button-1>", self._handle_click, add="+")
        else:
            self._accent = None
            self._dot = None
            self._label = None
            self._canvas = None
            self._preview = None

        self._visible   = False
        self._editor_win = None
        self._settings_win = None
        self._dialog_requested = False
        self._pending_settings_payload = None
        self._cmd_queue: queue.Queue = queue.Queue()
        self._root.after(50,  self._poll)
        self._root.after(33,  self._animate)   # 30 fps animation loop

    # ── Thread-safe public commands ──────────────────────────────────────

    def show_rec(self, preview: str = ""):
        self._cmd_queue.put(("rec", preview))

    def show_processing(self, preview: str = ""):
        self._cmd_queue.put(("processing", preview))

    def hide(self):
        self._cmd_queue.put(("hide", ""))

    def edit_text(self, title: str, initial_text: str, on_save, reset_text: str | None = None):
        self._dialog_requested = True
        self._cmd_queue.put((
            "edit_text",
            {
                "title": title,
                "initial_text": initial_text,
                "on_save": on_save,
                "reset_text": reset_text,
            },
        ))

    def edit_settings(self, state: dict, on_save, on_open_log, on_restart=None,
                      defer_until_hidden: bool = False):
        self._dialog_requested = True
        self._cmd_queue.put((
            "edit_settings",
            {
                "state": state,
                "on_save": on_save,
                "on_open_log": on_open_log,
                "on_restart": on_restart,
                "defer_until_hidden": defer_until_hidden,
            },
        ))

    def set_click_action(self, on_click) -> None:
        self._on_click = on_click

    def quit(self):
        self._cmd_queue.put(("quit", ""))

    def mainloop(self):
        self._root.mainloop()

    # ── Internal (main thread only) ──────────────────────────────────────

    def _poll(self):
        try:
            while True:
                cmd, preview = self._cmd_queue.get_nowait()
                if cmd == "quit":
                    if self._native_surface is not None:
                        self._native_surface.hide()
                    self._root.destroy()
                    sys.exit(0)
                elif cmd == "hide":
                    if self._is_native_surface:
                        self._native_surface.hide()
                    elif self._has_open_or_pending_dialogs():
                        self._move_overlay_offscreen()
                    else:
                        self._root.withdraw()
                    self._visible = False
                    self._state   = "hidden"
                    if self._pending_settings_payload is not None:
                        payload = self._pending_settings_payload
                        self._pending_settings_payload = None
                        self._root.after(10, lambda payload=payload: self._open_settings_editor(payload))
                elif cmd == "edit_text":
                    self._open_text_editor(preview)
                elif cmd == "edit_settings":
                    if preview.get("defer_until_hidden") and self._visible:
                        self._pending_settings_payload = preview
                    else:
                        self._open_settings_editor(preview)
                else:
                    self._state = cmd
                    if self._is_native_surface:
                        self._native_surface.set_state(cmd, preview)
                    else:
                        col   = _COL_REC  if cmd == "rec" else _COL_PROC
                        label = " REC"    if cmd == "rec" else " ..."
                        self._accent.configure(bg=col)
                        self._dot.configure(fg=col)
                        self._label.configure(text=label)
                        for rid in self._bar_ids:
                            self._canvas.itemconfigure(rid, fill=col)
                        if preview:
                            self._preview.configure(text=preview)
                            self._preview.pack(fill="x")
                        else:
                            self._preview.pack_forget()
                    if not self._visible:
                        self._position()
                        if self._is_native_surface:
                            self._native_surface.show(self._monitor)
                        else:
                            self._root.attributes("-alpha", 1.0)
                            self._root.deiconify()
                        self._visible = True
                    else:
                        self._reposition()
        except queue.Empty:
            pass
        self._root.after(50, self._poll)

    def _handle_click(self, _event):
        if not self._visible or self._on_click is None:
            return None
        self._on_click()
        return "break"

    def _has_open_dialogs(self) -> bool:
        return any(
            win is not None and win.winfo_exists()
            for win in (self._editor_win, self._settings_win)
        )

    def _has_open_or_pending_dialogs(self) -> bool:
        return (
            self._dialog_requested
            or self._pending_settings_payload is not None
            or self._has_open_dialogs()
        )

    def _move_overlay_offscreen(self) -> None:
        if self._is_native_surface:
            self._native_surface.move_offscreen()
            return
        self._root.attributes("-alpha", 0.0)
        self._root.geometry("1x1+-2000+-2000")

    def _animate(self):
        if self._visible and self._state != "hidden":
            t = time.perf_counter()
            if self._state == "rec":
                raw   = self._get_level()
                level = min(raw * 14.0, 1.0)   # typical mic RMS is 0.01–0.07
                for i in range(_N_BARS):
                    phase = i * 0.75
                    freq  = 4.5 + i * 0.4
                    wave  = (math.sin(t * freq + phase) + 1) / 2
                    # Quiet idle: gentle low ripple; loud: bars jump high
                    target = _BAR_MIN_H + (_BAR_MAX_H - _BAR_MIN_H) * (
                        level * 0.75 + wave * (0.25 + level * 0.15)
                    )
                    self._bar_h[i] = self._bar_h[i] * 0.5 + target * 0.5
            else:
                # Processing: smooth travelling sine sweep
                for i in range(_N_BARS):
                    wave   = (math.sin(t * 3.5 + i * 0.75) + 1) / 2
                    target = _BAR_MIN_H + (_BAR_MAX_H - _BAR_MIN_H) * wave * 0.55
                    self._bar_h[i] = self._bar_h[i] * 0.6 + target * 0.4

            y_base = _CANVAS_H - 2
            if self._is_native_surface:
                self._native_surface.set_bar_heights(self._bar_h)
            else:
                for i, (rid, h) in enumerate(zip(self._bar_ids, self._bar_h)):
                    x0 = 2 + i * (_BAR_W + _BAR_GAP)
                    x1 = x0 + _BAR_W
                    self._canvas.coords(rid, x0, y_base - int(h), x1, y_base)

        self._root.after(33, self._animate)

    def _open_text_editor(self, payload):
        self._dialog_requested = False
        if self._editor_win is not None and self._editor_win.winfo_exists():
            self._editor_win.deiconify()
            self._editor_win.lift()
            self._editor_win.focus_force()
            return

        title = payload["title"]
        initial_text = payload["initial_text"]
        on_save = payload["on_save"]
        reset_text = payload.get("reset_text")

        win = tk.Toplevel(self._root)
        self._editor_win = win
        win.title(title)
        win.geometry("760x520")
        win.minsize(520, 360)
        win.configure(bg=_OVL_BG)

        body = tk.Frame(win, bg=_OVL_BG, padx=12, pady=12)
        body.pack(fill="both", expand=True)

        label = tk.Label(
            body,
            text="Changes are saved to settings.json and used for future formatter runs.",
            fg=_COL_TEXT,
            bg=_OVL_BG,
            anchor="w",
            justify="left",
        )
        label.pack(fill="x", pady=(0, 8))

        editor = scrolledtext.ScrolledText(
            body,
            wrap="word",
            font=("Consolas", 10),
            undo=True,
            padx=8,
            pady=8,
        )
        editor.pack(fill="both", expand=True)
        editor.insert("1.0", initial_text)
        editor.focus_set()

        buttons = tk.Frame(body, bg=_OVL_BG)
        buttons.pack(fill="x", pady=(10, 0))

        def _close():
            if win.winfo_exists():
                win.destroy()
            self._editor_win = None
            if not self._visible and not self._has_open_or_pending_dialogs():
                self._root.withdraw()

        def _save():
            text = editor.get("1.0", "end-1c")
            try:
                on_save(text)
            except Exception as e:
                messagebox.showerror("voice-type", str(e), parent=win)
                return
            _close()

        def _reset():
            if reset_text is None:
                return
            editor.delete("1.0", "end")
            editor.insert("1.0", reset_text)

        tk.Button(buttons, text="Save", command=_save, width=10).pack(side="right")
        tk.Button(buttons, text="Cancel", command=_close, width=10).pack(side="right", padx=(0, 8))
        if reset_text is not None:
            tk.Button(buttons, text="Reset Default", command=_reset, width=14).pack(side="left")

        win.protocol("WM_DELETE_WINDOW", _close)

    def _open_settings_editor(self, payload):
        self._dialog_requested = False
        if self._settings_win is not None and self._settings_win.winfo_exists():
            self._settings_win.deiconify()
            self._settings_win.lift()
            self._settings_win.focus_force()
            return

        state = payload["state"]
        on_save = payload["on_save"]
        on_open_log = payload["on_open_log"]
        on_restart = payload.get("on_restart")

        def _choice_maps(options: list[str], labels: dict[str, str]):
            value_to_label = {value: labels.get(value, value) for value in options}
            label_to_value = {label: value for value, label in value_to_label.items()}
            return value_to_label, label_to_value

        final_v2l, final_l2v = _choice_maps(state["final_model_options"], state["model_labels"])
        stream_v2l, stream_l2v = _choice_maps(state["stream_model_options"], state["model_labels"])
        output_v2l, output_l2v = _choice_maps(state["output_mode_options"], state["output_mode_labels"])
        formatter_v2l, formatter_l2v = _choice_maps(
            state["formatter_model_options"], state["formatter_model_labels"]
        )

        win = tk.Toplevel(self._root)
        self._settings_win = win
        win.title("Voice Type Settings")
        win.geometry("560x420")
        win.minsize(520, 380)

        body = ttk.Frame(win, padding=14)
        body.pack(fill="both", expand=True)
        body.columnconfigure(1, weight=1)

        ttk.Label(
            body,
            text="Save changes to update the running app and persist them to settings.json. Startup changes apply on the next login.",
            justify="left",
        ).grid(row=0, column=0, columnspan=2, sticky="w", pady=(0, 12))

        enabled_var = tk.BooleanVar(value=bool(state["enabled"]))
        startup_var = tk.BooleanVar(value=bool(state["startup_enabled"]))
        formatter_enabled_var = tk.BooleanVar(value=bool(state["formatter_enabled"]))

        final_var = tk.StringVar(value=final_v2l[state["final_model"]])
        stream_var = tk.StringVar(value=stream_v2l[state["stream_model"]])
        output_var = tk.StringVar(value=output_v2l[state["output_mode"]])
        formatter_var = tk.StringVar(value=formatter_v2l[state["formatter_model"]])

        row = 1

        ttk.Checkbutton(body, text="Voice Type Enabled", variable=enabled_var).grid(
            row=row, column=0, columnspan=2, sticky="w", pady=(0, 8)
        )
        row += 1

        ttk.Checkbutton(body, text="Run on Startup", variable=startup_var).grid(
            row=row, column=0, columnspan=2, sticky="w", pady=(0, 14)
        )
        row += 1

        ttk.Label(body, text="Final Model").grid(row=row, column=0, sticky="w", pady=4)
        final_combo = ttk.Combobox(
            body,
            textvariable=final_var,
            values=[final_v2l[value] for value in state["final_model_options"]],
            state="readonly",
        )
        final_combo.grid(row=row, column=1, sticky="ew", pady=4)
        row += 1

        ttk.Label(body, text="Preview Model").grid(row=row, column=0, sticky="w", pady=4)
        stream_combo = ttk.Combobox(
            body,
            textvariable=stream_var,
            values=[stream_v2l[value] for value in state["stream_model_options"]],
            state="readonly",
        )
        stream_combo.grid(row=row, column=1, sticky="ew", pady=4)
        row += 1

        ttk.Label(body, text="Output Mode").grid(row=row, column=0, sticky="w", pady=4)
        output_combo = ttk.Combobox(
            body,
            textvariable=output_var,
            values=[output_v2l[value] for value in state["output_mode_options"]],
            state="readonly",
        )
        output_combo.grid(row=row, column=1, sticky="ew", pady=4)
        row += 1

        ttk.Checkbutton(body, text="Formatter Enabled", variable=formatter_enabled_var).grid(
            row=row, column=0, columnspan=2, sticky="w", pady=(10, 4)
        )
        row += 1

        ttk.Label(body, text="Formatter Model").grid(row=row, column=0, sticky="w", pady=4)
        formatter_combo = ttk.Combobox(
            body,
            textvariable=formatter_var,
            values=[formatter_v2l[value] for value in state["formatter_model_options"]],
            state="readonly",
        )
        formatter_combo.grid(row=row, column=1, sticky="ew", pady=4)
        row += 1

        buttons = ttk.Frame(body)
        buttons.grid(row=row, column=0, columnspan=2, sticky="ew", pady=(18, 0))
        buttons.columnconfigure(0, weight=1)

        def _sync_formatter_state():
            formatter_combo.configure(
                state="readonly" if formatter_enabled_var.get() else "disabled"
            )

        def _close():
            if win.winfo_exists():
                win.destroy()
            self._settings_win = None
            if not self._visible and not self._has_open_or_pending_dialogs():
                self._root.withdraw()

        def _save():
            updates = {
                "enabled": enabled_var.get(),
                "startup_enabled": startup_var.get(),
                "final_model": final_l2v[final_var.get()],
                "stream_model": stream_l2v[stream_var.get()],
                "output_mode": output_l2v[output_var.get()],
                "formatter_enabled": formatter_enabled_var.get(),
                "formatter_model": formatter_l2v[formatter_var.get()],
            }
            try:
                on_save(updates)
            except Exception as e:
                messagebox.showerror("voice-type", str(e), parent=win)
                return
            _close()

        formatter_enabled_var.trace_add("write", lambda *_args: _sync_formatter_state())
        _sync_formatter_state()

        left_buttons = ttk.Frame(buttons)
        left_buttons.grid(row=0, column=0, sticky="w")
        ttk.Button(left_buttons, text="Open Log", command=on_open_log).pack(side="left")

        if on_restart is not None:
            def _restart():
                if not messagebox.askyesno(
                    "voice-type",
                    "Restart Voice Type now?\n\n"
                    "This kills the current process — clearing any stuck "
                    "overlay — and relaunches it. Use this as a last resort "
                    "if the overlay is frozen.",
                    parent=win,
                ):
                    return
                try:
                    on_restart()
                except Exception as e:
                    messagebox.showerror(
                        "voice-type", f"Restart failed: {e}", parent=win
                    )

            ttk.Button(left_buttons, text="Restart", command=_restart).pack(
                side="left", padx=(8, 0)
            )

        ttk.Button(buttons, text="Cancel", command=_close).grid(row=0, column=1, sticky="e", padx=(0, 8))
        ttk.Button(buttons, text="Save", command=_save).grid(row=0, column=2, sticky="e")

        win.protocol("WM_DELETE_WINDOW", _close)
        win.focus_force()

    def _position(self):
        """Position at bottom-centre of the monitor holding the focused window."""
        try:
            self._monitor = platform.get_foreground_monitor_work_area()
        except Exception:
            self._monitor = (0, 0,
                             self._root.winfo_screenwidth(),
                             self._root.winfo_screenheight())
        self._do_geometry()

    def _reposition(self):
        """Re-centre after size changes (preview text appearing/disappearing)."""
        if self._monitor is None:
            self._position()
            return
        self._do_geometry()

    def _do_geometry(self):
        if self._is_native_surface:
            self._native_surface.reposition(self._monitor)
            return
        left, _, right, bottom = self._monitor
        self._root.update_idletasks()
        w = self._root.winfo_reqwidth()
        h = self._root.winfo_reqheight()
        x = left + (right - left) // 2 - w // 2
        y = bottom - h - 20
        self._root.geometry(f"+{x}+{y}")


# ---------------------------------------------------------------------------
# Audio recorder
# ---------------------------------------------------------------------------

class Recorder:
    """Owns the microphone stream and captures audio while recording.

    Windows keeps the stream open to minimize activation delay. macOS closes
    it while idle so the system microphone indicator is only shown while
    actively recording.
    """

    def __init__(self):
        self._frames: list[np.ndarray] = []
        self._lock = threading.Lock()
        self._recording = False
        self._stream_error = False  # set on any callback status; triggers restart on next key press
        self._keep_stream_open = should_keep_mic_stream_open_local()
        self._stream: sd.InputStream | None = None
        if self._keep_stream_open:
            self._open_stream()

    def _open_stream(self):
        info = sd.query_devices(DEVICE, "input")
        log(f"Mic: {info['name']!r}")
        # blocksize=256 → 16 ms per callback — low enough that the first
        # captured block is ≤16 ms after the key goes down.
        self._stream = sd.InputStream(
            samplerate=SAMPLE_RATE, channels=CHANNELS, dtype=DTYPE,
            device=DEVICE, callback=self._callback, blocksize=256,
        )
        self._stream.start()

    def _close_stream(self):
        if self._stream is None:
            return
        # Stopping a PortAudio stream from a non-callback thread can deadlock
        # inside CoreAudio's HAL (lock-ordering race against the audio IO
        # thread). Run it on a throwaway thread with a timeout so a deadlock
        # leaks one thread instead of wedging the whole app. The next
        # _ensure_stream() will open a fresh stream.
        stream = self._stream
        self._stream = None

        def _do_close():
            try:
                stream.stop()
                stream.close()
            except Exception as e:
                log(f"Stream close error (ignored): {e}")

        t = threading.Thread(target=_do_close, daemon=True,
                             name="voice-type-stream-close")
        t.start()
        t.join(timeout=STREAM_CLOSE_TIMEOUT)
        if t.is_alive():
            log(f"Stream close timed out after {STREAM_CLOSE_TIMEOUT}s "
                "(CoreAudio deadlock?); abandoning stream, will reopen on next use.")

    def _ensure_stream(self):
        """Restart the audio stream if it's dead or errored.

        Called on each key press. Handles suspend/resume and device resets -
        after Windows wakes from sleep the portaudio device can silently die
        while the sd.InputStream object still thinks it's active.
        """
        if self._stream is None:
            self._open_stream()
            self._stream_error = False
            return

        needs_restart = self._stream_error or not self._stream.active
        if not needs_restart:
            return
        reason = "error flag set" if self._stream_error else "stream inactive"
        log(f"Audio stream needs restart ({reason}), reconnecting...")
        self._close_stream()
        try:
            self._open_stream()
            self._stream_error = False
            log("Audio stream restarted successfully.")
        except Exception as e:
            log(f"Audio stream restart failed: {e}")

    def start(self):
        self._ensure_stream()
        with self._lock:
            self._frames    = []
            self._recording = True

    def peek(self) -> np.ndarray:
        """Non-destructive snapshot of all audio recorded so far."""
        with self._lock:
            if not self._frames:
                return np.array([], dtype=np.float32)
            return np.concatenate(self._frames, axis=0).flatten()

    def get_rms(self) -> float:
        """RMS of the last ~100 ms of audio — drives the waveform animation."""
        with self._lock:
            if not self._frames:
                return 0.0
            recent = np.concatenate(self._frames[-2:], axis=0).flatten()
            if len(recent) == 0:
                return 0.0
            return float(np.sqrt(np.mean(recent ** 2)))

    def stop(self) -> np.ndarray:
        with self._lock:
            self._recording = False
            if not self._frames:
                audio = np.array([], dtype=np.float32)
            else:
                audio = np.concatenate(self._frames, axis=0).flatten()

        if not self._keep_stream_open:
            self._close_stream()

        if len(audio) == 0:
            return audio

        dur = len(audio) / SAMPLE_RATE
        rms = float(np.sqrt(np.mean(audio ** 2)))
        peak = float(np.max(np.abs(audio)))
        log(f"Stopped: {dur:.2f}s  rms={rms:.4f}  peak={peak:.4f}")
        return audio

    def _callback(self, indata, frames, time_info, status):
        if status:
            log(f"Audio status: {status}")
            self._stream_error = True   # flag for restart on next key press
        if self._recording:
            self._frames.append(indata.copy())


# ---------------------------------------------------------------------------
# Transcription
# ---------------------------------------------------------------------------

def transcribe(audio: np.ndarray, verbose: bool = True, on_segment=None) -> str:
    """Transcribe audio using the final model.

    on_segment: optional callable(text: str) called for each non-empty segment
    as it is decoded, before the full result is assembled. Used by hybrid and
    stabilized modes to act on partial output early.
    """
    duration = len(audio) / SAMPLE_RATE
    if duration < 0.3:
        return ""
    model    = get_model()
    segments, info = model.transcribe(
        audio,
        language="en",
        vad_filter=False,
        beam_size=1,
        condition_on_previous_text=False,
    )
    parts = []
    for seg in segments:
        text = seg.text.strip()
        if text:
            parts.append(text)
            if on_segment:
                on_segment(text)
    result = _apply_corrections(" ".join(parts).strip())
    if verbose:
        log(f"Transcribed {duration:.1f}s → {result!r}  "
            f"(lang={info.language} p={info.language_probability:.2f})")
    return result


# ---------------------------------------------------------------------------
# Streaming transcriber — runs while key is held
# ---------------------------------------------------------------------------

class StreamingTranscriber:
    def __init__(self, recorder: Recorder, overlay: Overlay):
        self._recorder = recorder
        self._overlay  = overlay
        self._active   = False
        self._last_text = ""

    def start(self):
        if self._active:
            # Already streaming — a second _loop thread would double every
            # log line and waste CPU re-transcribing the same buffer.
            return
        self._active    = True
        self._last_text = ""
        threading.Thread(target=self._loop, daemon=True).start()

    def stop(self):
        """Signal the streaming loop to stop. Final transcription is always done by the caller."""
        self._active = False

    @property
    def last_preview(self) -> str:
        return _wrap_preview(self._last_text)

    def _loop(self):
        time.sleep(STREAM_INTERVAL)
        while self._active:
            model = get_stream_model()
            if model is None:
                # Stream model still loading — skip this tick silently
                time.sleep(STREAM_INTERVAL)
                continue

            audio = self._recorder.peek()
            if len(audio) >= SAMPLE_RATE * STREAM_MIN_AUDIO:
                if not self._active:
                    break
                t0 = time.perf_counter()
                # Use the dedicated stream model — never contends with _model_lock
                segs, _ = model.transcribe(
                    audio, language="en", vad_filter=False,
                    beam_size=1, condition_on_previous_text=False,
                )
                text = " ".join(s.text.strip() for s in segs).strip()
                if not self._active:
                    break
                elapsed = time.perf_counter() - t0
                log(f"Stream pass: {len(audio)/SAMPLE_RATE:.1f}s → {elapsed:.2f}s → {text[:60]!r}")
                self._last_text = text
                self._overlay.show_rec(_wrap_preview(text))
            time.sleep(STREAM_INTERVAL)


# ---------------------------------------------------------------------------
# Final-model precompute worker — runs while key is held (precompute mode)
# ---------------------------------------------------------------------------

class FinalPrecomputer:
    """Periodically runs the final model on a growing audio snapshot while the
    user is still recording. At key-up we can reuse the latest snapshot result
    and only finalize the tail, which reduces post-release latency."""

    def __init__(self, recorder: Recorder):
        self._recorder = recorder
        self._active = False
        self._lock = threading.Lock()
        self._best_text = ""
        self._best_samples = 0
        self._last_requested_samples = 0
        self._run_id = 0
        self._thread: threading.Thread | None = None
        self._inflight = False

    def start(self):
        with self._lock:
            self._best_text = ""
            self._best_samples = 0
            self._last_requested_samples = 0
            self._run_id += 1
            run_id = self._run_id
            self._inflight = False
        self._active = True
        self._thread = threading.Thread(target=self._loop, args=(run_id,), daemon=True)
        self._thread.start()

    def stop(self, wait: float = 0.0):
        self._active = False
        if wait > 0 and self._thread is not None:
            self._thread.join(timeout=wait)

    def snapshot(self) -> tuple[str, int]:
        with self._lock:
            return self._best_text, self._best_samples

    def _loop(self, run_id: int):
        min_samples = int(PRECOMP_MIN_AUDIO * SAMPLE_RATE)
        delta_samples = int(PRECOMP_MIN_DELTA * SAMPLE_RATE)
        while self._active:
            with self._lock:
                if run_id != self._run_id:
                    break
            audio = self._recorder.peek()
            n_samples = len(audio)
            if n_samples < min_samples:
                time.sleep(PRECOMP_IDLE_SLEEP)
                continue
            with self._lock:
                last_requested = self._last_requested_samples
            if n_samples < last_requested + delta_samples:
                time.sleep(PRECOMP_IDLE_SLEEP)
                continue

            with self._lock:
                self._last_requested_samples = n_samples
                self._inflight = True

            t0 = time.perf_counter()
            try:
                text = transcribe(audio, verbose=False)
            except Exception as e:
                log(f"[precompute] pass failed: {e}")
                with self._lock:
                    self._inflight = False
                time.sleep(PRECOMP_IDLE_SLEEP)
                continue
            elapsed = time.perf_counter() - t0
            with self._lock:
                if n_samples >= self._best_samples:
                    self._best_samples = n_samples
                    self._best_text = text
                self._inflight = False
            log(f"[precompute] pass: {n_samples / SAMPLE_RATE:.1f}s -> {elapsed:.2f}s")
            # No fixed interval here, run again as soon as enough new audio exists.
            if not self._active:
                break


# ---------------------------------------------------------------------------
# Text injection
# ---------------------------------------------------------------------------

def paste_text(text: str):
    if not text.strip():
        return
    title = platform.get_foreground_window_title()
    log(f"Injecting into {title!r}: {text!r}")
    time.sleep(0.05)
    platform.inject_text(text, log)
    time.sleep(0.05)


# ---------------------------------------------------------------------------
# Finalize helpers (one per output mode)
# ---------------------------------------------------------------------------

def _merge_text(base: str, tail: str) -> str:
    """Merge base + tail transcripts with a simple overlap heuristic."""
    base = base.strip()
    tail = tail.strip()
    if not base:
        return tail
    if not tail:
        return base
    if tail.startswith(base):
        return tail
    if base.endswith(tail):
        return base

    max_overlap = min(len(base), len(tail), 240)
    overlap = 0
    for k in range(max_overlap, 0, -1):
        if base[-k:].lower() == tail[:k].lower():
            overlap = k
            break
    if overlap > 0:
        merged = base + tail[overlap:]
        return merged.strip()
    return f"{base} {tail}".strip()


def _finish_one_shot(audio: np.ndarray, overlay: "Overlay", tray: "TrayIcon",
                     t0: float, mode: str):
    """final_only and hybrid: wait for full transcription then inject once.

    hybrid differs from final_only only in that it updates the overlay text
    live as each segment arrives, giving visual feedback during the wait.
    """
    on_seg = None
    if mode == "hybrid":
        def on_seg(text: str):
            overlay.show_processing(_wrap_preview(text))

    try:
        text = transcribe(audio, on_segment=on_seg)
    except Exception as e:
        log(f"Transcription error [{mode}]: {e}")
        text = ""

    elapsed = time.perf_counter() - t0
    overlay.hide()
    tray.set_state("idle")
    if text:
        text = _maybe_format_final_text(text, mode)
        log(f"Done ({elapsed:.2f}s) [{mode}]: {text!r}")
        paste_text(text)
    else:
        log(f"Nothing to paste ({elapsed:.2f}s) [{mode}].")


def _finish_precompute(audio: np.ndarray, overlay: "Overlay", tray: "TrayIcon",
                       t0: float, base_text: str, base_samples: int):
    """Precompute mode: reuse best in-recording snapshot, then transcribe tail."""
    overlap_samples = int(PRECOMP_OVERLAP * SAMPLE_RATE)
    total_samples = len(audio)
    use_base = bool(base_text and base_samples > 0 and base_samples < total_samples)
    if base_samples > 0:
        lag = max(0.0, (total_samples - base_samples) / SAMPLE_RATE)
        log(f"[precompute] snapshot lag: {lag:.2f}s")

    try:
        if use_base:
            tail_start = max(0, base_samples - overlap_samples)
            tail_audio = audio[tail_start:]
            log(f"[precompute] base={base_samples / SAMPLE_RATE:.1f}s "
                f"tail={len(tail_audio) / SAMPLE_RATE:.1f}s")
            tail_text = transcribe(tail_audio)
            text = _merge_text(base_text, tail_text)
        else:
            if base_text and base_samples >= total_samples:
                log("[precompute] using full precomputed transcript.")
                text = base_text
            else:
                log("[precompute] no usable base snapshot, falling back to full pass.")
                text = transcribe(audio)
    except Exception as e:
        log(f"Transcription error [precompute]: {e}")
        text = ""

    elapsed = time.perf_counter() - t0
    overlay.hide()
    tray.set_state("idle")
    if text:
        text = _maybe_format_final_text(text, "precompute")
        log(f"Done ({elapsed:.2f}s) [precompute]: {text!r}")
        paste_text(text)
    else:
        log(f"Nothing to paste ({elapsed:.2f}s) [precompute].")


def _finish_stabilized(audio: np.ndarray, overlay: "Overlay", tray: "TrayIcon",
                       t0: float):
    """Stabilized: inject segments as decoded, then run bounded tail correction."""
    title = platform.get_foreground_window_title()
    log(f"[stabilized] target: {title!r}")

    injected_parts: list[str] = []
    first_char_t: list[float | None] = [None]

    def _commit(text: str):
        prefix = " " if injected_parts else ""
        if not injected_parts:
            time.sleep(0.05)   # brief settle before first keystroke
            first_char_t[0] = time.perf_counter()
        platform.inject_text(prefix + text, log)
        injected_parts.append(text)
        overlay.show_processing(_wrap_preview(text))
        log(f"[stabilized] commit: {text!r}")

    def on_segment(text: str):
        # Segments are decoded with condition_on_previous_text=False so each
        # one is independent and won't be revised when later segments arrive.
        # Commit immediately rather than holding back — this is what makes
        # stabilized faster than final_only.
        _commit(text)

    try:
        full_text = transcribe(audio, on_segment=on_segment)
    except Exception as e:
        log(f"Transcription error [stabilized]: {e}")
        overlay.hide()
        tray.set_state("idle")
        log(f"Done (error) [stabilized].")
        return

    # Tail correction: compare what we typed against the final joined result.
    # With beam_size=1 and condition_on_previous_text=False the segments are
    # independent, so this usually matches. If there is a difference (e.g. a
    # space at a segment boundary), find the common prefix and fix only the tail.
    injected_text = " ".join(injected_parts)
    if injected_text and injected_text != full_text:
        log(f"[stabilized] tail correction needed: {injected_text!r} -> {full_text!r}")
        common = 0
        for a, b in zip(injected_text, full_text):
            if a == b:
                common += 1
            else:
                break
        to_delete = len(injected_text) - common
        tail      = full_text[common:]
        log(f"[stabilized] delete {to_delete} chars, append {tail!r}")
        if to_delete > 0:
            platform.inject_backspaces(to_delete, log)
            time.sleep(0.02)
        if tail:
            platform.inject_text(tail, log)

    elapsed = time.perf_counter() - t0
    overlay.hide()
    tray.set_state("idle")
    if first_char_t[0] is not None:
        log(f"[stabilized] first char +{first_char_t[0] - t0:.2f}s, total {elapsed:.2f}s")
    if full_text:
        log(f"Done ({elapsed:.2f}s) [stabilized]: {full_text!r}")
    else:
        log(f"Nothing to paste ({elapsed:.2f}s) [stabilized].")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def run():
    # Keep the heartbeat fresh across the (potentially slow) import + startup
    # window, before the hotkey loop takes over refreshing it.
    _write_heartbeat()
    _load_settings()
    log(
        "Settings: "
        f"final_model={_settings['final_model']!r}  "
        f"stream_model={_settings['stream_model']!r}  "
        f"output_mode={_settings['output_mode']!r}  "
        f"formatter_enabled={_settings['formatter_enabled']!r}  "
        f"formatter_model={_settings['formatter_model']!r}"
    )

    recorder = Recorder()
    overlay  = Overlay(get_level=recorder.get_rms)
    streamer = StreamingTranscriber(recorder, overlay)
    precomputer = FinalPrecomputer(recorder)
    tray_class = MacTrayIcon if sys.platform == "darwin" else TrayIcon
    tray     = tray_class(overlay)
    control_server = None
    if sys.platform == "darwin":
        control_server = _make_control_server(tray, overlay)
        control_server.start()
        overlay._root.after(0, tray.start)
        overlay._root.after(0, platform.setup_process)
    else:
        tray.start()
        platform.setup_process()

    def hotkey_worker():
        # Load main model first, then stream model (sequenced to avoid CPU contention)
        threading.Thread(target=get_model, daemon=True).start()
        threading.Thread(target=_load_stream_model, daemon=True).start()
        if _settings.get("formatter_enabled", False):
            def _warm_formatter_after_startup():
                get_model()
                _load_stream_model()
                get_text_formatter()

            threading.Thread(target=_warm_formatter_after_startup, daemon=True).start()
        import sys as _sys
        _hotkey_label = "F12" if _sys.platform == "darwin" else "Right Ctrl"
        log(f"Ready. Hold {_hotkey_label} to record.")

        was_down = False
        down_since = 0.0
        forced_stop = False
        last_heartbeat = 0.0
        while True:
            # Refresh the heartbeat so a freshly-launched instance can tell
            # whether we are alive or wedged. This loop stops ticking if a
            # key-up handler deadlocks (e.g. in CoreAudio), letting the next
            # launch detect the stale heartbeat and take over.
            now = time.monotonic()
            if now - last_heartbeat >= _HEARTBEAT_INTERVAL:
                _write_heartbeat()
                last_heartbeat = now

            raw_down = platform.is_hotkey_down()
            # forced_stop latches a force-stop so we ignore a stuck-down key
            # until it is genuinely released again.
            if not raw_down:
                forced_stop = False
            is_down = raw_down and not forced_stop

            if is_down and was_down and time.monotonic() - down_since > MAX_RECORDING_SECONDS:
                log(f"--- Recording exceeded {MAX_RECORDING_SECONDS}s safety cap; force-stopping ---")
                forced_stop = True
                is_down = False

            if is_down and not was_down:
                if not tray.enabled:
                    pass  # silently ignore while disabled
                else:
                    log("--- Key DOWN ---")
                    down_since = time.monotonic()
                    platform.snapshot_target_app()
                    tray.set_state("recording")
                    overlay.show_rec()
                    recorder.start()
                    streamer.start()
                    mode = _effective_output_mode()
                    if mode == "precompute":
                        precomputer.start()
                    else:
                        precomputer.stop()

            elif not is_down and was_down:
                if tray.enabled:
                    log("--- Key UP ---")
                    # Stop the streaming preview loop FIRST: if recorder.stop()
                    # deadlocks inside CoreAudio, the streamer is already
                    # halted so the overlay/CPU don't spin forever.
                    streamer.stop()   # signal stream loop; final pass always runs below
                    audio = recorder.stop()
                    mode = _effective_output_mode()
                    if mode == "precompute":
                        precomputer.stop(wait=PRECOMP_STOP_WAIT)
                    else:
                        precomputer.stop()
                    pre_state = precomputer.snapshot()

                    def _finish(audio=audio, preview=streamer.last_preview, pre_state=pre_state):
                        # Show "processing" with the last streaming preview so the
                        # user sees what was recognised so far while we finalise.
                        mode = _effective_output_mode()
                        overlay.show_processing(preview)
                        tray.set_state("processing")
                        t0 = time.perf_counter()
                        log(f"Finalize mode: {mode!r}")
                        if mode == "precompute":
                            base_text, base_samples = pre_state
                            _finish_precompute(audio, overlay, tray, t0, base_text, base_samples)
                        elif mode == "stabilized":
                            _finish_stabilized(audio, overlay, tray, t0)
                        else:
                            _finish_one_shot(audio, overlay, tray, t0, mode)

                    threading.Thread(target=_finish, daemon=True).start()

            was_down = is_down
            time.sleep(POLL_INTERVAL)

    threading.Thread(target=hotkey_worker, daemon=True).start()

    # Tkinter mainloop MUST run on the main thread on Windows
    try:
        overlay.mainloop()
    finally:
        if control_server is not None:
            control_server.stop()


if __name__ == "__main__":
    try:
        run()
    except KeyboardInterrupt:
        sys.exit(0)
