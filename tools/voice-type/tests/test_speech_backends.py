import importlib.util
import pathlib
import sys
import unittest


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOLS_DIR / "speech_backends.py"


def load_module():
    spec = importlib.util.spec_from_file_location("speech_backends", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class SpeechBackendsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_resolve_mlx_repo_prefers_arm_macos(self):
        repo = self.module.resolve_mlx_repo(
            system="darwin",
            machine="arm64",
            model_name="small.en",
            has_mlx=True,
        )
        self.assertEqual("mlx-community/whisper-small.en-mlx", repo)

    def test_resolve_mlx_repo_returns_none_without_mlx(self):
        repo = self.module.resolve_mlx_repo(
            system="darwin",
            machine="arm64",
            model_name="small.en",
            has_mlx=False,
        )
        self.assertIsNone(repo)

    def test_resolve_mlx_repo_returns_none_for_non_macos(self):
        repo = self.module.resolve_mlx_repo(
            system="win32",
            machine="arm64",
            model_name="small.en",
            has_mlx=True,
        )
        self.assertIsNone(repo)

    def test_resolve_mlx_repo_returns_none_for_unmapped_model(self):
        repo = self.module.resolve_mlx_repo(
            system="darwin",
            machine="arm64",
            model_name="parakeet-tdt-0.6b",
            has_mlx=True,
        )
        self.assertIsNone(repo)


if __name__ == "__main__":
    unittest.main()
