import importlib.util
import unittest
from pathlib import Path


PROCESSOR_PATH = Path(__file__).parents[1] / "record_meeting_processor.py"
SPEC = importlib.util.spec_from_file_location("record_meeting_processor", PROCESSOR_PATH)
PROCESSOR = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(PROCESSOR)


class ProcessorTests(unittest.TestCase):
    def test_longest_turn_for_each_speaker(self):
        turns = [
            PROCESSOR.SpeakerTurn(0, 1, "SPEAKER_00"),
            PROCESSOR.SpeakerTurn(2, 8, "SPEAKER_00"),
            PROCESSOR.SpeakerTurn(9, 12, "SPEAKER_01"),
        ]

        samples = PROCESSOR.sample_turns(turns, maximum_duration=4)

        self.assertEqual(samples["SPEAKER_00"], (2, 4))
        self.assertEqual(samples["SPEAKER_01"], (9, 3))

    def test_mix_filter_handles_all_audio_streams(self):
        self.assertEqual(PROCESSOR.mix_filter(1), (["-map", "0:a:0"], None))
        self.assertEqual(
            PROCESSOR.mix_filter(3),
            (
                [
                    "-filter_complex",
                    "[0:a:0][0:a:1][0:a:2]amix=inputs=3:duration=longest:normalize=0[a]",
                    "-map",
                    "[a]",
                ],
                "[a]",
            ),
        )


if __name__ == "__main__":
    unittest.main()
