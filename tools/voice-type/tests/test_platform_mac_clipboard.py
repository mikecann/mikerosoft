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

    def paste(self, pasteboard, post_paste):
        return self.module._paste_via_pasteboard(
            pasteboard,
            "dictated words",
            post_paste,
            make_item=LazyTextItem,
            item_class=FakePasteboardItem,
            timeout=0.05,
        )

    def test_restores_old_clipboard_after_the_target_reads_the_text(self):
        pasteboard = FakePasteboard(
            [FakePasteboardItem({"public.utf8-plain-text": b"old clipboard"})]
        )

        latency = self.paste(pasteboard, lambda: pasteboard.items[0].read())

        self.assertIsNotNone(latency)
        self.assertEqual(
            [{"public.utf8-plain-text": b"old clipboard"}],
            [item.values for item in pasteboard.items],
        )

    def test_keeps_text_on_clipboard_when_the_target_never_reads_it(self):
        pasteboard = FakePasteboard(
            [FakePasteboardItem({"public.utf8-plain-text": b"old clipboard"})]
        )

        latency = self.paste(pasteboard, lambda: None)

        self.assertIsNone(latency)
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

        self.paste(pasteboard, target_reads_then_user_copies)

        self.assertEqual(
            [{"public.utf8-plain-text": "newer copy"}],
            [item.values for item in pasteboard.items],
        )


if __name__ == "__main__":
    unittest.main()
