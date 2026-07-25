from __future__ import annotations

import sys


WAKE_RESUME_GAP_SECONDS = 30.0


def should_keep_mic_stream_open(platform_name: str) -> bool:
    return False


def should_keep_mic_stream_open_local() -> bool:
    return should_keep_mic_stream_open(sys.platform)


def should_restart_after_loop_gap(
    *,
    platform_name: str,
    previous_wall_time: float,
    current_wall_time: float,
) -> bool:
    if platform_name != "darwin":
        return False
    gap = current_wall_time - previous_wall_time
    return gap > WAKE_RESUME_GAP_SECONDS
