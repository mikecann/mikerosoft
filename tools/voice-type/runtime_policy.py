from __future__ import annotations

import sys


WAKE_RESUME_GAP_SECONDS = 30.0
PREVIEW_OUTPUT_MODES = frozenset({"final_only", "hybrid", "stabilized", "precompute"})


def should_keep_mic_stream_open(platform_name: str) -> bool:
    return False


def should_keep_mic_stream_open_local() -> bool:
    return should_keep_mic_stream_open(sys.platform)


def should_stream_preview(output_mode: str) -> bool:
    """Return whether a recording mode should update the transcript overlay.

    Output modes control finalization and text injection. They do not change
    the user's expectation that speech appears in the live preview.
    """
    return output_mode in PREVIEW_OUTPUT_MODES


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
