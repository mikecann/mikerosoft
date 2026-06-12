import importlib.util
import sys
import tempfile
import unittest
import wave
from pathlib import Path
from types import SimpleNamespace


SCRIPT = Path(__file__).with_name("transcribe.py")
SPEC = importlib.util.spec_from_file_location("transcribe_tool", SCRIPT)
transcribe_tool = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules["transcribe_tool"] = transcribe_tool
SPEC.loader.exec_module(transcribe_tool)


class TranscribeSpeakerTests(unittest.TestCase):
    def test_reads_pyannote_community_output_shape(self):
        output = SimpleNamespace(
            speaker_diarization=[
                (SimpleNamespace(start=0.5, end=2.0), "SPEAKER_00"),
                (SimpleNamespace(start=2.0, end=3.5), "SPEAKER_01"),
            ],
        )

        self.assertEqual(
            transcribe_tool.speaker_turns_from_pyannote_output(output),
            [
                transcribe_tool.SpeakerTurn(0.5, 2.0, "SPEAKER_00"),
                transcribe_tool.SpeakerTurn(2.0, 3.5, "SPEAKER_01"),
            ],
        )

    def test_assigns_speaker_with_most_overlap(self):
        segments = [
            SimpleNamespace(start=0.0, end=3.0, text="Hello there"),
            SimpleNamespace(start=3.0, end=5.0, text="Nice to meet you"),
        ]
        turns = [
            transcribe_tool.SpeakerTurn(0.0, 1.0, "SPEAKER_00"),
            transcribe_tool.SpeakerTurn(1.0, 3.0, "SPEAKER_01"),
            transcribe_tool.SpeakerTurn(3.0, 5.0, "SPEAKER_00"),
        ]

        assigned = transcribe_tool.assign_speakers_to_segments(segments, turns)

        self.assertEqual(
            assigned,
            [
                transcribe_tool.TranscriptSegment(0.0, 3.0, "Hello there", "SPEAKER_01"),
                transcribe_tool.TranscriptSegment(3.0, 5.0, "Nice to meet you", "SPEAKER_00"),
            ],
        )

    def test_srt_includes_speaker_label_when_present(self):
        segments = [
            transcribe_tool.TranscriptSegment(0.0, 1.25, "Hello there", "SPEAKER_00"),
            transcribe_tool.TranscriptSegment(1.25, 3.0, "Nice to meet you", None),
        ]

        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out.srt"
            transcribe_tool.write_srt(out, segments)

            self.assertEqual(
                out.read_text(encoding="utf-8"),
                "1\n"
                "00:00:00,000 --> 00:00:01,250\n"
                "[SPEAKER_00] Hello there\n\n"
                "2\n"
                "00:00:01,250 --> 00:00:03,000\n"
                "Nice to meet you\n\n",
            )

    def test_resolves_huggingface_token_from_common_env_names(self):
        old_hf = transcribe_tool.os.environ.get("HF_TOKEN")
        old_huggingface = transcribe_tool.os.environ.get("HUGGINGFACE_TOKEN")
        try:
            transcribe_tool.os.environ.pop("HF_TOKEN", None)
            transcribe_tool.os.environ["HUGGINGFACE_TOKEN"] = "from-env"

            self.assertEqual(transcribe_tool.resolve_huggingface_token(None), "from-env")
            self.assertEqual(transcribe_tool.resolve_huggingface_token("from-arg"), "from-arg")
        finally:
            if old_hf is None:
                transcribe_tool.os.environ.pop("HF_TOKEN", None)
            else:
                transcribe_tool.os.environ["HF_TOKEN"] = old_hf
            if old_huggingface is None:
                transcribe_tool.os.environ.pop("HUGGINGFACE_TOKEN", None)
            else:
                transcribe_tool.os.environ["HUGGINGFACE_TOKEN"] = old_huggingface

    def test_load_dotenv_file_sets_missing_values_without_overwriting_env(self):
        old_existing = transcribe_tool.os.environ.get("EXISTING_KEY")
        old_new = transcribe_tool.os.environ.get("NEW_KEY")
        try:
            transcribe_tool.os.environ["EXISTING_KEY"] = "from-env"
            transcribe_tool.os.environ.pop("NEW_KEY", None)

            with tempfile.TemporaryDirectory() as tmp:
                env_file = Path(tmp) / ".env"
                env_file.write_text(
                    "# comment\n"
                    "EXISTING_KEY=from-file\n"
                    "NEW_KEY=from-file\n",
                    encoding="utf-8",
                )

                transcribe_tool.load_dotenv_file(env_file)

            self.assertEqual(transcribe_tool.os.environ["EXISTING_KEY"], "from-env")
            self.assertEqual(transcribe_tool.os.environ["NEW_KEY"], "from-file")
        finally:
            if old_existing is None:
                transcribe_tool.os.environ.pop("EXISTING_KEY", None)
            else:
                transcribe_tool.os.environ["EXISTING_KEY"] = old_existing
            if old_new is None:
                transcribe_tool.os.environ.pop("NEW_KEY", None)
            else:
                transcribe_tool.os.environ["NEW_KEY"] = old_new

    def test_load_wav_for_pyannote_returns_waveform_dict(self):
        with tempfile.TemporaryDirectory() as tmp:
            wav_path = Path(tmp) / "sample.wav"
            with wave.open(str(wav_path), "wb") as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(16000)
                wav.writeframes((0).to_bytes(2, "little", signed=True) * 160)

            audio = transcribe_tool.load_wav_for_pyannote(wav_path)

        self.assertEqual(audio["sample_rate"], 16000)
        self.assertEqual(tuple(audio["waveform"].shape), (1, 160))


if __name__ == "__main__":
    unittest.main()
