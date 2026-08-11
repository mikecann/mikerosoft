"""Safe transcript stitching for low-latency finalization.

The final model transcribes most of the recording while the key is still held.
At key-up Voice Type transcribes a short overlapping tail. This module joins
those two results only when there is a clear word boundary. An uncertain join
returns ``None`` so the caller can preserve accuracy with a full transcription.
"""

from __future__ import annotations

import re


_WORD_RE = re.compile(r"[\w']+", re.UNICODE)
_MIN_OVERLAP_WORDS = 2


def _words(text: str) -> list[tuple[str, int, int]]:
    return [
        (match.group(0).casefold(), match.start(), match.end())
        for match in _WORD_RE.finditer(text)
    ]


def _capitalize_after_sentence(base: str, remainder: str) -> str:
    if not base.rstrip().endswith((".", "?", "!")):
        return remainder
    for index, char in enumerate(remainder):
        if char.isalpha():
            return remainder[:index] + char.upper() + remainder[index + 1 :]
    return remainder


def merge_overlapping_transcripts(base: str, tail: str) -> str | None:
    """Join two transcripts when their word overlap is unambiguous.

    Punctuation and capitalization are ignored while locating the overlap, but
    the precomputed base and the new portion of the tail keep their original
    formatting. A one-word match is too easy to hit accidentally, so it is not
    accepted as proof of a safe join.
    """
    base = base.strip()
    tail = tail.strip()
    if not base:
        return tail
    if not tail:
        return base

    base_words = _words(base)
    tail_words = _words(tail)
    max_overlap = min(len(base_words), len(tail_words))

    overlap = 0
    for count in range(max_overlap, _MIN_OVERLAP_WORDS - 1, -1):
        if (
            [word for word, _start, _end in base_words[-count:]]
            == [word for word, _start, _end in tail_words[:count]]
        ):
            overlap = count
            break

    if overlap == 0:
        return None
    if overlap == len(tail_words):
        return base

    # Start at the first genuinely new word. This intentionally drops commas
    # or other punctuation attached to the duplicated overlap in the tail.
    remainder_start = tail_words[overlap][1]
    remainder = _capitalize_after_sentence(base, tail[remainder_start:].lstrip())
    separator = "" if base.endswith((" ", "\n")) else " "
    return f"{base}{separator}{remainder}".strip()
