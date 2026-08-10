"""Pure health predicates shared by Voice Type and its restart script."""

from __future__ import annotations

from typing import Any


MAX_PROCESSING_AGE_SECONDS = 180.0


def _base_health(state: dict[str, Any]) -> bool:
    return (
        state.get("hotkey_listener") == "event-tap"
        and state.get("final_model_status") == "ready"
        and not state.get("backend_poisoned", False)
    )


def is_restart_ready(state: dict[str, Any]) -> bool:
    """A restart is proven ready only after the whole dictation path is ready."""
    return _base_health(state) and state.get("ui_state") == "idle"


def is_runtime_healthy(state: dict[str, Any]) -> bool:
    """Allow legitimate work, but reject a stale processing state."""
    if not _base_health(state):
        return False
    if state.get("ui_state") != "processing":
        return True
    try:
        age = float(state.get("ui_state_age_seconds", float("inf")))
    except (TypeError, ValueError):
        return False
    return age < MAX_PROCESSING_AGE_SECONDS
