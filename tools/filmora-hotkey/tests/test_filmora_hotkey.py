import importlib.util
import sys
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "filmora_hotkey.py"
SPEC = importlib.util.spec_from_file_location("filmora_hotkey", MODULE_PATH)
filmora_hotkey = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = filmora_hotkey
SPEC.loader.exec_module(filmora_hotkey)


class FilmoraHotkeyTests(unittest.TestCase):
    def test_f16_press_guard_activates_once_until_key_is_released(self):
        activations = []
        guard = filmora_hotkey.F16PressGuard(lambda: activations.append("toggle"))

        guard.press(is_f16=True)
        guard.press(is_f16=True)
        guard.release(is_f16=True)
        guard.press(is_f16=True)

        self.assertEqual(activations, ["toggle", "toggle"])

    def test_f16_press_guard_ignores_other_keys(self):
        activations = []
        guard = filmora_hotkey.F16PressGuard(lambda: activations.append("toggle"))

        guard.press(is_f16=False)
        guard.release(is_f16=False)

        self.assertEqual(activations, [])

    def test_setup_accepts_uv_managed_python(self):
        setup_script = (MODULE_PATH.parent / "setup_mac.sh").read_text()

        self.assertIn('$HOME/.local/bin/python3', setup_script)

    def test_find_play_pause_item_walks_view_menu(self):
        tree = {
            "menu-bar": ["file", "view"],
            "file": ["file-menu"],
            "view": ["view-menu"],
            "view-menu": ["play", "loop"],
        }
        titles = {
            "file": "File",
            "view": "View",
            "play": "Play / Pause",
            "loop": "Loop Playback Range",
        }

        item = filmora_hotkey.find_play_pause_item(
            "menu-bar",
            get_children=lambda element: tree.get(element, []),
            get_title=lambda element: titles.get(element),
        )

        self.assertEqual(item, "play")

    def test_toggle_reports_success(self):
        pressed_pids = []

        result = filmora_hotkey.toggle_filmora_playback(
            find_pid=lambda: 123,
            press_play_pause=lambda pid: pressed_pids.append(pid) or True,
        )

        self.assertTrue(result.ok)
        self.assertEqual(result.message, "Filmora playback toggled")
        self.assertEqual(pressed_pids, [123])

    def test_toggle_reports_when_filmora_is_not_running(self):
        result = filmora_hotkey.toggle_filmora_playback(
            find_pid=lambda: None,
            press_play_pause=lambda pid: True,
        )

        self.assertFalse(result.ok)
        self.assertEqual(result.message, "Filmora is not running")

    def test_toggle_reports_accessibility_failure(self):
        def denied(_pid):
            raise PermissionError("not trusted")

        result = filmora_hotkey.toggle_filmora_playback(
            find_pid=lambda: 123,
            press_play_pause=denied,
        )

        self.assertFalse(result.ok)
        self.assertIn("Accessibility", result.message)


if __name__ == "__main__":
    unittest.main()
