from __future__ import annotations

import pathlib
import time

from text_formatter import (
    DEFAULT_FORMATTER_MODEL,
    FORMATTER_MODEL_PRESETS,
    LlamaCppFormatter,
    validate_formatted_text,
)


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent

SAMPLE_TEXTS = [
    ("before-example", (SCRIPT_DIR / "before.txt").read_text(encoding="utf-8").strip()),
    (
        "code-review-note",
        "Yeah, update the collect to be a take and I'm just wondering as well this given task Because we're doing the take and we're not specifying anywhere in the task or a comment or anything like that We probably it's going to confuse the model because they're going to raise that point probably that we are selecting a subset so we may well be missing data for the user. So maybe we should just put some comments or something saying, it's a known thing returning only a subset at this point or something like that.",
    ),
    (
        "convex-note",
        "So instead of doing the Promise All, we can just do it in a For loop instead. Let's do that because it's just as fast, or almost exactly as fast, in Convex. fast in convex and will flag the M plus 1 issue even more, which will be good.",
    ),
]


def benchmark_model(model_key: str):
    formatter = LlamaCppFormatter(model_key)
    started = time.perf_counter()
    formatter.warm()
    warm_ms = (time.perf_counter() - started) * 1000.0

    rows = []
    for name, text in SAMPLE_TEXTS:
        started = time.perf_counter()
        output = formatter(text)
        elapsed_ms = (time.perf_counter() - started) * 1000.0
        decision = validate_formatted_text(text, output)
        rows.append((name, elapsed_ms, decision.reason, output))
    return warm_ms, rows


def main():
    print(f"default_model={DEFAULT_FORMATTER_MODEL}")
    for model_key in FORMATTER_MODEL_PRESETS:
        preset = FORMATTER_MODEL_PRESETS[model_key]
        print("")
        print(f"## {preset.label}")
        warm_ms, rows = benchmark_model(model_key)
        print(f"warm_ms={warm_ms:.0f}")
        for name, elapsed_ms, reason, output in rows:
            print(f"[{name}] latency_ms={elapsed_ms:.0f} validation={reason}")
            print(output)
            print("")


if __name__ == "__main__":
    main()
