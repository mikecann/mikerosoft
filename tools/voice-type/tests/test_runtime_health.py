import importlib.util
import pathlib
import sys
import unittest


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOLS_DIR / "runtime_health.py"


def load_module():
    spec = importlib.util.spec_from_file_location("runtime_health", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class RuntimeHealthTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_restart_readiness_requires_idle_ready_model_and_event_tap(self):
        state = {
            "hotkey_listener": "event-tap",
            "ui_state": "idle",
            "final_model_status": "ready",
            "backend_poisoned": False,
        }

        self.assertTrue(self.module.is_restart_ready(state))

        for key, value in (
            ("hotkey_listener", "fallback"),
            ("ui_state", "processing"),
            ("final_model_status", "loading"),
            ("backend_poisoned", True),
        ):
            unhealthy = dict(state)
            unhealthy[key] = value
            self.assertFalse(self.module.is_restart_ready(unhealthy), (key, value))

    def test_stale_processing_is_unhealthy_even_if_other_signals_are_live(self):
        state = {
            "hotkey_listener": "event-tap",
            "ui_state": "processing",
            "ui_state_age_seconds": 181.0,
            "final_model_status": "ready",
            "backend_poisoned": False,
        }

        self.assertFalse(self.module.is_runtime_healthy(state))

    def test_fresh_finalization_is_runtime_healthy(self):
        state = {
            "hotkey_listener": "event-tap",
            "ui_state": "processing",
            "ui_state_age_seconds": 5.0,
            "final_model_status": "ready",
            "backend_poisoned": False,
        }

        self.assertTrue(self.module.is_runtime_healthy(state))


if __name__ == "__main__":
    unittest.main()
