from __future__ import annotations


MAX_PREVIEW_CHARS = 32
LEADING_ELLIPSIS = "\u2026"


def wrap_preview(text: str, max_chars: int = MAX_PREVIEW_CHARS) -> str:
    """Word-wrap preview text to the last two lines."""
    if not text:
        return ""

    words = text.split()
    lines: list[str] = []
    current = ""

    for word in words:
        if current and len(current) + 1 + len(word) > max_chars:
            lines.append(current)
            current = word
        else:
            current = (current + " " + word).lstrip()

    if current:
        lines.append(current)

    if not lines:
        return ""

    visible = lines[-2:]
    prefix = LEADING_ELLIPSIS if len(lines) > 2 else ""
    return prefix + "\n".join(visible)
