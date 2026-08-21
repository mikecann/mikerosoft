"""Resolve and validate the microphone before accepting a dictation."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

import numpy as np


DEFAULT_MICROPHONE_NAME = "Yeti Stereo Microphone"


class MicrophoneUnavailable(RuntimeError):
    pass


@dataclass(frozen=True)
class InputDevice:
    index: int | None
    name: str


@dataclass(frozen=True)
class MicrophoneProbeResult:
    ready: bool
    device: InputDevice
    reason: str = ""


def list_input_devices(sounddevice) -> list[InputDevice]:
    """Return selectable input devices with duplicate names removed."""
    devices = []
    seen_names = set()
    for index, info in enumerate(sounddevice.query_devices()):
        name = str(info.get("name", "")).strip()
        normalized_name = name.casefold()
        if (
            not name
            or int(info.get("max_input_channels", 0)) <= 0
            or normalized_name in seen_names
        ):
            continue
        devices.append(InputDevice(index=index, name=name))
        seen_names.add(normalized_name)
    return devices


def input_device_options(
    sounddevice,
    selected_name: str | None,
) -> tuple[list[str], set[str]]:
    """Build settings choices, retaining an unplugged saved device."""
    devices = list_input_devices(sounddevice)
    options = [""]
    options.extend(device.name for device in devices)
    available_names = {device.name.casefold() for device in devices}
    selected = (selected_name or "").strip()
    if selected and selected.casefold() not in available_names:
        options.append(selected)
    return options, available_names


def microphone_candidate(
    *,
    preferred_name: str | None,
    elapsed_seconds: float,
    preferred_wait_seconds: float,
) -> str | None:
    """Choose the preferred mic during its wake grace period, then default."""
    preferred = (preferred_name or "").strip()
    if preferred and elapsed_seconds < preferred_wait_seconds:
        return preferred
    return None


def resolve_input_device(sounddevice, preferred_name: str | None) -> InputDevice:
    """Resolve an explicit input device without silently falling back.

    PortAudio's default device can be stale immediately after macOS wakes. If
    a preferred microphone is configured, using the laptop microphone instead
    would make a recording appear healthy while capturing the wrong source.
    """
    preferred = (preferred_name or "").strip()
    if not preferred:
        info = sounddevice.query_devices(None, "input")
        return InputDevice(index=None, name=str(info["name"]))

    devices = sounddevice.query_devices()
    exact_matches = [
        (index, info)
        for index, info in enumerate(devices)
        if int(info.get("max_input_channels", 0)) > 0
        and str(info.get("name", "")).casefold() == preferred.casefold()
    ]
    if len(exact_matches) == 1:
        index, info = exact_matches[0]
        return InputDevice(index=index, name=str(info["name"]))

    raise MicrophoneUnavailable(
        f"Configured microphone {preferred!r} is not available"
    )


def probe_input_device(
    sounddevice,
    *,
    preferred_name: str | None,
    sample_rate: int,
    channels: int,
    dtype: str,
    duration_seconds: float = 0.35,
    sleep: Callable[[float], None],
) -> MicrophoneProbeResult:
    """Open the selected mic briefly and reject CoreAudio digital silence."""
    device = resolve_input_device(sounddevice, preferred_name)
    chunks: list[np.ndarray] = []

    def callback(indata, _frames, _time_info, _status):
        chunks.append(indata.copy())

    stream = sounddevice.InputStream(
        samplerate=sample_rate,
        channels=channels,
        dtype=dtype,
        device=device.index,
        callback=callback,
        blocksize=256,
    )
    try:
        stream.start()
        sleep(duration_seconds)
    finally:
        try:
            stream.stop()
        finally:
            stream.close()

    if not chunks:
        return MicrophoneProbeResult(False, device, "no samples")

    audio = np.concatenate(chunks, axis=0).flatten()
    rms = float(np.sqrt(np.mean(audio ** 2))) if len(audio) else 0.0
    peak = float(np.max(np.abs(audio))) if len(audio) else 0.0
    if rms <= 0.000001 and peak <= 0.00001:
        return MicrophoneProbeResult(False, device, "digital silence")
    return MicrophoneProbeResult(True, device)


def refresh_audio_devices(sounddevice) -> None:
    """Refresh PortAudio's device snapshot after wake or USB enumeration."""
    sounddevice._terminate()
    sounddevice._initialize()


def resolve_recording_input(
    sounddevice,
    *,
    preferred_name: str | None,
    platform_name: str,
) -> InputDevice:
    """Refresh macOS device state, then resolve the saved input choice."""
    if platform_name == "darwin":
        refresh_audio_devices(sounddevice)
    return resolve_input_device(sounddevice, preferred_name)


def resolve_current_default_input(sounddevice, *, platform_name: str) -> InputDevice:
    """Resolve the current system default instead of PortAudio's stale cache."""
    return resolve_recording_input(
        sounddevice,
        preferred_name=None,
        platform_name=platform_name,
    )
