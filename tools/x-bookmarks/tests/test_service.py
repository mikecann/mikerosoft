import pathlib
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from service import launchagent, install_runtime


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

    def test_runtime_survives_source_checkout_removal(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            source = root / 'source'
            source.mkdir()
            for name in ('bookmarks.py', 'cli_delivery.py', 'oauth.py', 'service.py', 'x-bookmarks'):
                (source / name).write_text('# runtime')
            script = install_runtime(source, root / 'state')
            (source / 'bookmarks.py').unlink()
            self.assertEqual(script.read_text(), '# runtime')
            self.assertTrue((script.parent / 'cli_delivery.py').exists())


if __name__ == "__main__":
    unittest.main()
