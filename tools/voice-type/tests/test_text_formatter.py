import importlib.util
import pathlib
import sys
import time
import unittest


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOLS_DIR / "text_formatter.py"


def load_module():
    spec = importlib.util.spec_from_file_location("text_formatter", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class TextFormatterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()
        cls.before_text = (TOOLS_DIR / "before.txt").read_text(encoding="utf-8").strip()
        cls.after_text = (TOOLS_DIR / "after.txt").read_text(encoding="utf-8").strip()

    def test_applies_only_to_whole_transcript_modes(self):
        self.assertTrue(self.module.formatter_applies_to_mode("final_only"))
        self.assertTrue(self.module.formatter_applies_to_mode("hybrid"))
        self.assertTrue(self.module.formatter_applies_to_mode("precompute"))
        self.assertFalse(self.module.formatter_applies_to_mode("stabilized"))

    def test_build_messages_uses_default_system_prompt(self):
        messages = self.module.build_formatter_messages("hello there")
        self.assertEqual(
            self.module.DEFAULT_FORMATTER_SYSTEM_PROMPT,
            messages[0]["content"],
        )

    def test_build_messages_uses_custom_system_prompt(self):
        messages = self.module.build_formatter_messages(
            "hello there",
            system_prompt="Custom prompt",
        )
        self.assertEqual("Custom prompt", messages[0]["content"])

    def test_before_after_example_is_accepted(self):
        decision = self.module.validate_formatted_text(self.before_text, self.after_text)
        self.assertTrue(decision.accepted, decision.reason)

    def test_rejects_empty_output(self):
        decision = self.module.validate_formatted_text("hello there", "")
        self.assertFalse(decision.accepted)
        self.assertEqual("empty-output", decision.reason)

    def test_rejects_large_length_change(self):
        decision = self.module.validate_formatted_text(
            "one two three four five six seven eight",
            "one two",
        )
        self.assertFalse(decision.accepted)
        self.assertEqual("length-change-too-large", decision.reason)

    def test_rejects_number_removal(self):
        decision = self.module.validate_formatted_text(
            "Project 42 ships in 2026.",
            "Project ships soon.",
        )
        self.assertFalse(decision.accepted)
        self.assertEqual("numbers-removed", decision.reason)

    def test_formatter_returns_original_when_disabled(self):
        result = self.module.format_for_injection(
            self.before_text,
            enabled=False,
            mode="final_only",
            formatter=lambda text: self.after_text,
        )
        self.assertEqual(self.before_text, result.text)
        self.assertEqual("disabled", result.reason)

    def test_formatter_uses_fake_response_when_safe(self):
        result = self.module.format_for_injection(
            self.before_text,
            enabled=True,
            mode="final_only",
            formatter=lambda text: self.after_text,
        )
        self.assertEqual(self.after_text, result.text)
        self.assertTrue(result.used_formatter)
        self.assertEqual("accepted", result.reason)

    def test_formatter_falls_back_when_output_is_rejected(self):
        result = self.module.format_for_injection(
            "Project 42 ships in 2026.",
            enabled=True,
            mode="precompute",
            formatter=lambda text: "Project ships soon.",
        )
        self.assertEqual("Project 42 ships in 2026.", result.text)
        self.assertFalse(result.used_formatter)
        self.assertEqual("numbers-removed", result.reason)

    def test_formatter_falls_back_when_backend_raises(self):
        def boom(_text: str) -> str:
            raise RuntimeError("nope")

        result = self.module.format_for_injection(
            "hello there",
            enabled=True,
            mode="final_only",
            formatter=boom,
        )
        self.assertEqual("hello there", result.text)
        self.assertFalse(result.used_formatter)
        self.assertEqual("formatter-error", result.reason)

    def test_formatter_falls_back_on_timeout(self):
        def slow(_text: str) -> str:
            time.sleep(0.05)
            return "Hello there."

        result = self.module.format_for_injection(
            "hello there",
            enabled=True,
            mode="final_only",
            formatter=slow,
            timeout_sec=0.01,
        )
        self.assertEqual("hello there", result.text)
        self.assertFalse(result.used_formatter)
        self.assertEqual("formatter-timeout", result.reason)

    def test_stabilized_mode_skips_formatter(self):
        result = self.module.format_for_injection(
            "hello there",
            enabled=True,
            mode="stabilized",
            formatter=lambda text: "Hello there.",
        )
        self.assertEqual("hello there", result.text)
        self.assertFalse(result.used_formatter)
        self.assertEqual("unsupported-mode", result.reason)


if __name__ == "__main__":
    unittest.main()
