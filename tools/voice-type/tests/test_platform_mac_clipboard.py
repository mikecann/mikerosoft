import importlib.util
import pathlib
import unittest


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOLS_DIR / "platform_mac.py"


def load_module():
    spec = importlib.util.spec_from_file_location("platform_mac_clipboard", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class FakePasteboardItem:
    def __init__(self, values=None):
        self.values = dict(values or {})

    @classmethod
    def alloc(cls):
        return cls()

    def init(self):
        return self

    def types(self):
        return list(self.values)

    def dataForType_(self, pasteboard_type):
        return self.values.get(pasteboard_type)

    def setData_forType_(self, data, pasteboard_type):
        self.values[pasteboard_type] = data
        return True


class FakePasteboard:
    def __init__(self, items):
        self.items = list(items)
        self.clear_count = 0
        self.change_count = 0

    def changeCount(self):
        return self.change_count

    def setString_forType_(self, text, pasteboard_type):
        self.change_count += 1
        self.items = [FakePasteboardItem({pasteboard_type: text})]
        return True

    def pasteboardItems(self):
        return self.items

    def clearContents(self):
        self.clear_count += 1
        self.change_count += 1
        self.items = []

    def writeObjects_(self, items):
        self.items = list(items)
        return True


class LazyTextItem(FakePasteboardItem):
    """Stands in for an NSPasteboardItem backed by a data provider."""

    def __init__(self, text, on_read):
        super().__init__()
        self.text = text
        self.on_read = on_read

    def read(self):
        self.values["public.utf8-plain-text"] = self.text
        self.on_read()


class PlatformMacClipboardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_snapshot_and_restore_preserves_image_and_text_clipboard_types(self):
        pasteboard = FakePasteboard(
            [
                FakePasteboardItem(
                    {
                        "public.png": b"PNG image bytes",
                        "public.tiff": b"TIFF image bytes",
                    }
                ),
                FakePasteboardItem({"public.utf8-plain-text": b"caption"}),
            ]
        )

        snapshot = self.module._snapshot_pasteboard(pasteboard)
        pasteboard.clearContents()
        self.module._restore_pasteboard(
            pasteboard,
            snapshot,
            item_class=FakePasteboardItem,
        )

        self.assertEqual(2, len(pasteboard.items))
        self.assertEqual(
            {
                "public.png": b"PNG image bytes",
                "public.tiff": b"TIFF image bytes",
            },
            pasteboard.items[0].values,
        )
        self.assertEqual(
            {"public.utf8-plain-text": b"caption"},
            pasteboard.items[1].values,
        )

    def test_restore_preserves_an_empty_clipboard(self):
        pasteboard = FakePasteboard([])

        snapshot = self.module._snapshot_pasteboard(pasteboard)
        pasteboard.items = [FakePasteboardItem({"public.utf8-plain-text": b"voice"})]
        self.module._restore_pasteboard(
            pasteboard,
            snapshot,
            item_class=FakePasteboardItem,
        )

        self.assertEqual([], pasteboard.items)
        self.assertEqual(1, pasteboard.clear_count)

    def paste(self, pasteboard, post_paste, landed=None):
        return self.module._paste_via_pasteboard(
            pasteboard,
            "dictated words",
            post_paste,
            landed=landed,
            make_item=LazyTextItem,
            item_class=FakePasteboardItem,
            timeout=0.05,
        )

    def test_restores_old_clipboard_after_the_target_reads_the_text(self):
        pasteboard = FakePasteboard(
            [FakePasteboardItem({"public.utf8-plain-text": b"old clipboard"})]
        )

        latency, pasted = self.paste(
            pasteboard,
            lambda: pasteboard.items[0].read(),
            landed=lambda: True,
        )

        self.assertIsNotNone(latency)
        self.assertTrue(pasted)
        self.assertEqual(
            [{"public.utf8-plain-text": b"old clipboard"}],
            [item.values for item in pasteboard.items],
        )

    def test_keeps_text_on_clipboard_when_the_target_never_reads_it(self):
        pasteboard = FakePasteboard(
            [FakePasteboardItem({"public.utf8-plain-text": b"old clipboard"})]
        )
        asked = []

        latency, pasted = self.paste(
            pasteboard,
            lambda: None,
            landed=lambda: asked.append(True) or True,
        )

        self.assertIsNone(latency)
        self.assertFalse(pasted)
        self.assertEqual([], asked)
        self.assertEqual(
            [{"public.utf8-plain-text": "dictated words"}],
            [item.values for item in pasteboard.items],
        )

    def test_keeps_text_on_clipboard_when_the_paste_found_no_text_box(self):
        pasteboard = FakePasteboard(
            [FakePasteboardItem({"public.utf8-plain-text": b"old clipboard"})]
        )

        latency, pasted = self.paste(
            pasteboard,
            lambda: pasteboard.items[0].read(),
            landed=lambda: False,
        )

        self.assertIsNotNone(latency)
        self.assertFalse(pasted)
        self.assertEqual(
            [{"public.utf8-plain-text": "dictated words"}],
            [item.values for item in pasteboard.items],
        )

    def test_does_not_restore_over_something_copied_after_the_paste(self):
        pasteboard = FakePasteboard(
            [FakePasteboardItem({"public.utf8-plain-text": b"old clipboard"})]
        )

        def target_reads_then_user_copies():
            pasteboard.items[0].read()
            pasteboard.setString_forType_("newer copy", "public.utf8-plain-text")

        self.paste(pasteboard, target_reads_then_user_copies, landed=lambda: True)

        self.assertEqual(
            [{"public.utf8-plain-text": "newer copy"}],
            [item.values for item in pasteboard.items],
        )

    def test_missed_paste_does_not_overwrite_something_copied_since(self):
        pasteboard = FakePasteboard(
            [FakePasteboardItem({"public.utf8-plain-text": b"old clipboard"})]
        )

        def target_reads_then_user_copies():
            pasteboard.items[0].read()
            pasteboard.setString_forType_("newer copy", "public.utf8-plain-text")

        _, pasted = self.paste(
            pasteboard,
            target_reads_then_user_copies,
            landed=lambda: False,
        )

        self.assertFalse(pasted)
        self.assertEqual(
            [{"public.utf8-plain-text": "newer copy"}],
            [item.values for item in pasteboard.items],
        )


class FocusedTextBoxTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_text_roles_are_editable(self):
        for role in ("AXTextArea", "AXTextField", "AXComboBox"):
            self.assertEqual("editable", self.module._classify_focus(role, False))

    def test_an_element_with_a_settable_value_is_editable(self):
        self.assertEqual("editable", self.module._classify_focus("AXGroup", True))

    def test_web_pages_groups_and_buttons_are_not_editable(self):
        for role in ("AXWebArea", "AXGroup", "AXButton"):
            self.assertEqual("not-editable", self.module._classify_focus(role, False))

    def test_no_role_is_unknown(self):
        self.assertEqual("unknown", self.module._classify_focus(None, False))

    def wait(self, states):
        remaining = list(states)
        calls = []

        def read_focus(pid):
            calls.append(pid)
            return remaining.pop(0) if len(remaining) > 1 else remaining[0]

        result = self.module._wait_for_text_box(
            42, read_focus=read_focus, wait=0.05, poll=0.001,
        )
        return result, calls

    def test_a_focused_text_box_is_accepted_straight_away(self):
        result, calls = self.wait([("editable", "AXTextArea")])

        self.assertEqual((True, "AXTextArea"), result)
        self.assertEqual([42], calls)

    def test_trusts_the_paste_when_accessibility_cannot_tell(self):
        result, _ = self.wait([("unknown", None)])

        self.assertEqual((True, None), result)

    def test_reports_no_text_box_when_focus_never_becomes_editable(self):
        result, calls = self.wait([("not-editable", "AXGroup")])

        self.assertEqual((False, "AXGroup"), result)
        self.assertGreater(len(calls), 1)

    def test_accepts_an_app_moving_the_paste_into_its_text_box(self):
        result, _ = self.wait([
            ("not-editable", "AXWebArea"),
            ("not-editable", "AXWebArea"),
            ("editable", "AXTextArea"),
        ])

        self.assertEqual((True, "AXTextArea"), result)


if __name__ == "__main__":
    unittest.main()
