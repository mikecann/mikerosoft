import importlib.util
import pathlib
import unittest


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOLS_DIR / "platform_mac.py"


def load_module():
    spec = importlib.util.spec_from_file_location("platform_mac_hotkeys", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class PlatformMacHotkeyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_only_right_control_activates_push_to_talk(self):
        hotkeys = self.module.MacPushToTalkHotkeys()

        self.assertTrue(hotkeys.handle_event("flags_changed", 0x3E, True))
        self.assertTrue(hotkeys.is_down())

        self.assertTrue(hotkeys.handle_event("flags_changed", 0x3E, False))
        self.assertFalse(hotkeys.is_down())

        self.assertFalse(hotkeys.handle_event("flags_changed", 0x3B, True))
        self.assertFalse(hotkeys.is_down())

    def test_f12_remains_active_when_right_control_is_released(self):
        hotkeys = self.module.MacPushToTalkHotkeys()

        self.assertTrue(hotkeys.handle_event("key_down", 111))
        self.assertTrue(hotkeys.handle_event("flags_changed", 0x3E, True))
        self.assertTrue(hotkeys.handle_event("flags_changed", 0x3E, False))
        self.assertTrue(hotkeys.is_down())

        self.assertTrue(hotkeys.handle_event("key_up", 111))
        self.assertFalse(hotkeys.is_down())

    def test_quartz_flags_changed_handles_right_control_not_left_control(self):
        class FakeQuartz:
            kCGEventKeyDown = 10
            kCGEventKeyUp = 11
            kCGEventFlagsChanged = 12
            kCGKeyboardEventKeycode = 9
            kCGEventSourceStateHIDSystemState = 1

            @staticmethod
            def CGEventGetIntegerValueField(event, field):
                return event["keycode"]

            @staticmethod
            def CGEventGetFlags(event):
                return event["flags"]

            @staticmethod
            def CGEventSourceKeyState(state, keycode):
                return False

        hotkeys = self.module.MacPushToTalkHotkeys()

        handled = self.module.handle_quartz_hotkey_event(
            FakeQuartz,
            FakeQuartz.kCGEventFlagsChanged,
            {"keycode": 0x3E, "flags": 270592},
            hotkeys,
        )
        self.assertTrue(handled)
        self.assertTrue(hotkeys.is_down())

        handled = self.module.handle_quartz_hotkey_event(
            FakeQuartz,
            FakeQuartz.kCGEventFlagsChanged,
            {"keycode": 0x3B, "flags": 270592},
            hotkeys,
        )
        self.assertFalse(handled)

        handled = self.module.handle_quartz_hotkey_event(
            FakeQuartz,
            FakeQuartz.kCGEventFlagsChanged,
            {"keycode": 0x3E, "flags": 256},
            hotkeys,
        )
        self.assertTrue(handled)
        self.assertFalse(hotkeys.is_down())


if __name__ == "__main__":
    unittest.main()
