import pathlib
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from service import launchagent


class ServiceTests(unittest.TestCase):
    def test_launchagent_uses_absolute_python_and_no_shell_or_llm(self):
        with tempfile.TemporaryDirectory(prefix="bookmark & spaces ") as tmp:
            root = pathlib.Path(tmp)
            data = launchagent(root, root / "config.json", root / "capture.py", root / "python3", root / "output.log")
            plist = plistlib.loads(plistlib.dumps(data))
            self.assertEqual(plist["ProgramArguments"], [str(root / "python3"), str(root / "capture.py"),
                            "--state-dir", str(root), "--config", str(root / "config.json"), "tick"])
            self.assertEqual(plist["StartInterval"], 60)
            self.assertNotIn("KeepAlive", plist)
            self.assertEqual(plist["StandardErrorPath"], str(root / "output.log"))


if __name__ == "__main__":
    unittest.main()
