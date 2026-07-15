import re
import unittest
from pathlib import Path


class KillScriptTests(unittest.TestCase):
    def test_pkill_patterns_are_anchored_to_known_taskbar_paths(self):
        script = Path(__file__).parents[1].joinpath("kill.sh").read_text()
        patterns = re.findall(r'^pkill -f "([^"]+)"', script, flags=re.MULTILINE)
        swift_patterns = [
            pattern
            for pattern in patterns
            if "APP_BIN" in pattern or "taskbar-swift" in pattern
        ]

        self.assertEqual(len(swift_patterns), 2)
        for pattern in swift_patterns:
            self.assertTrue(pattern.startswith("^"), pattern)
            self.assertTrue(pattern.endswith("$"), pattern)
            self.assertTrue("SCRIPT_DIR" in pattern or "APP_BIN" in pattern, pattern)

        self.assertNotIn('pkill -f "taskbar-swift"', script)


if __name__ == "__main__":
    unittest.main()
