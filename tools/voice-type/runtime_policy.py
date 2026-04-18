from __future__ import annotations

import sys


def should_keep_mic_stream_open(platform_name: str) -> bool:
    return platform_name == "win32"


def should_keep_mic_stream_open_local() -> bool:
    return should_keep_mic_stream_open(sys.platform)
