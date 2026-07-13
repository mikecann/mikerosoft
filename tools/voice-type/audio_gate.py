"""Audio-level guards for voice-type recordings."""


def should_skip_short_low_level_audio(
    *,
    duration_sec: float,
    rms: float,
    peak: float,
    max_duration_sec: float = 1.0,
    max_rms: float = 0.004,
    max_peak: float = 0.03,
) -> bool:
    """Return True for very short, near-silent clips likely to hallucinate."""
    return (
        duration_sec < max_duration_sec
        and rms < max_rms
        and peak < max_peak
    )
