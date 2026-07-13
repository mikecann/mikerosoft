import importlib.util
import pathlib
import sys
import unittest
from types import SimpleNamespace
from unittest import mock


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

    def test_mlx_transcribe_releases_cached_working_memory(self):
        cleared = []
        fake_mlx_whisper = SimpleNamespace(
            transcribe=lambda *_args, **_kwargs: {
                "text": "hello",
                "language": "en",
            }
        )
        fake_mlx_core = SimpleNamespace(clear_cache=lambda: cleared.append(True))

        with mock.patch.dict(
            sys.modules,
            {
                "mlx_whisper": fake_mlx_whisper,
                "mlx": SimpleNamespace(core=fake_mlx_core),
            },
        ):
            model = self.module.MlxWhisperModel(repo_id="test/repo")
            segments, _info = model.transcribe([0.0], language="en")

        self.assertEqual(["hello"], [segment.text for segment in segments])
        self.assertEqual([True], cleared)


if __name__ == "__main__":
    unittest.main()
