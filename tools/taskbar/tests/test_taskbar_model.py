import importlib.util
import pathlib
import unittest


TOOL_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOL_DIR / "taskbar_model.py"


def load_module():
    spec = importlib.util.spec_from_file_location("taskbar_model", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class TaskbarModelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.model = load_module()

    def record(self, owner, title, pid=100, window_id=1, **overrides):
        values = {
            "owner": owner,
            "title": title,
            "pid": pid,
            "window_id": window_id,
            "layer": 0,
            "is_on_screen": True,
            "bounds": {"X": 10, "Y": 20, "Width": 800, "Height": 600},
        }
        values.update(overrides)
        return self.model.WindowRecord(**values)

    def test_visible_windows_rejects_desktop_panels_and_tiny_helpers(self):
        records = [
            self.record("Safari", "Article", pid=10, window_id=1),
            self.record("Dock", "Dock", pid=11, window_id=2),
            self.record("Messages", "Badge", pid=12, window_id=3, bounds={"Width": 20, "Height": 20}),
            self.record("Finder", "Desktop", pid=13, window_id=4, layer=-2147483623),
            self.record("Notes", "Hidden", pid=14, window_id=5, is_on_screen=False),
        ]

        visible = self.model.visible_windows(records, current_pid=999)

        self.assertEqual(["Safari"], [window.owner for window in visible])

    def test_visible_windows_can_include_minimized_windows(self):
        records = [
            self.record("Safari", "Article", pid=10, window_id=1),
            self.record("Notes", "Plan", pid=11, window_id=2, is_on_screen=False, is_minimized=True),
            self.record("Finder", "Hidden", pid=12, window_id=3, is_on_screen=False),
        ]

        visible = self.model.visible_windows(records, current_pid=999, include_minimized=True)

        self.assertEqual(["Safari", "Notes"], [window.owner for window in visible])

    def test_visible_windows_rejects_the_taskbar_process(self):
        records = [
            self.record("Python", "mikerosoft taskbar", pid=42, window_id=1),
            self.record("Terminal", "zsh", pid=99, window_id=2),
        ]

        visible = self.model.visible_windows(records, current_pid=42)

        self.assertEqual(["Terminal"], [window.owner for window in visible])

    def test_build_items_groups_windows_by_running_app(self):
        windows = [
            self.record("Safari", "Article", pid=10, window_id=1),
            self.record("Safari", "Docs", pid=10, window_id=2),
            self.record("Terminal", "zsh", pid=20, window_id=3),
        ]

        items = self.model.build_taskbar_items(windows, frontmost_pid=None)

        self.assertEqual(["Safari", "Terminal"], [item.owner for item in items])
        self.assertEqual([2, 1], [item.window_count for item in items])
        self.assertEqual([[1, 2], [3]], [item.window_ids for item in items])

    def test_build_items_marks_frontmost_app_without_moving_it(self):
        windows = [
            self.record("Safari", "Article", pid=10, window_id=1),
            self.record("Terminal", "zsh", pid=20, window_id=2),
            self.record("Notes", "Planning", pid=30, window_id=3),
        ]

        items = self.model.build_taskbar_items(windows, frontmost_pid=20)

        self.assertEqual(["Notes", "Safari", "Terminal"], [item.owner for item in items])
        self.assertTrue(items[2].is_frontmost)


if __name__ == "__main__":
    unittest.main()
