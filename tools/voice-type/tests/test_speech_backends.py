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

    def test_default_stream_model_uses_accelerated_model_on_apple_silicon(self):
        model_name = self.module.resolve_default_whisper_model(
            accelerated_model="large-v3-turbo",
            fallback_model="tiny.en",
            cuda_available=False,
            system="darwin",
            machine="arm64",
            has_mlx=True,
        )
        self.assertEqual("large-v3-turbo", model_name)

    def test_default_stream_model_uses_fallback_without_gpu_backend(self):
        model_name = self.module.resolve_default_whisper_model(
            accelerated_model="large-v3-turbo",
            fallback_model="tiny.en",
            cuda_available=False,
            system="darwin",
            machine="x86_64",
            has_mlx=False,
        )
        self.assertEqual("tiny.en", model_name)

    def test_default_stream_model_uses_accelerated_model_with_cuda(self):
        model_name = self.module.resolve_default_whisper_model(
            accelerated_model="large-v3-turbo",
            fallback_model="tiny.en",
            cuda_available=True,
            system="win32",
            machine="amd64",
            has_mlx=False,
        )
        self.assertEqual("large-v3-turbo", model_name)

    def test_load_local_mlx_model_selects_turbo_repo_and_warms_model(self):
        warmed = []

        class FakeModel:
            def __init__(self, *, repo_id):
                self.repo_id = repo_id

            def warm(self):
                warmed.append(self.repo_id)

        model = self.module.load_local_mlx_model(
            model_name="large-v3-turbo",
            repo_resolver=lambda *, model_name: (
                self.module.MLX_REPOS_BY_MODEL[model_name]
            ),
            model_factory=FakeModel,
        )

        self.assertEqual(
            "mlx-community/whisper-large-v3-turbo",
            model.repo_id,
        )
        self.assertEqual(
            ["mlx-community/whisper-large-v3-turbo"],
            warmed,
        )

    def test_load_local_mlx_model_returns_none_when_mlx_is_unavailable(self):
        model = self.module.load_local_mlx_model(
            model_name="large-v3-turbo",
            repo_resolver=lambda *, model_name: None,
            model_factory=mock.Mock(side_effect=AssertionError("must not load")),
        )
        self.assertIsNone(model)

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

    def test_mlx_transcribe_releases_cache_when_transcription_fails(self):
        cleared = []

        def fail_transcription(*_args, **_kwargs):
            raise RuntimeError("transcription failed")

        with mock.patch.dict(
            sys.modules,
            {
                "mlx_whisper": SimpleNamespace(transcribe=fail_transcription),
                "mlx": SimpleNamespace(
                    core=SimpleNamespace(clear_cache=lambda: cleared.append(True))
                ),
            },
        ):
            model = self.module.MlxWhisperModel(repo_id="test/repo")
            with self.assertRaisesRegex(RuntimeError, "transcription failed"):
                model.transcribe([0.0], language="en")

        self.assertEqual([True], cleared)


if __name__ == "__main__":
    unittest.main()
