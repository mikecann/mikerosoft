from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


WORKER_ROOT = Path(__file__).resolve().parents[1] / "worker"
sys.path.insert(0, str(WORKER_ROOT))

from meeting_archive_worker.visual_labels import extract_visual_labels  # noqa: E402


class VisualLabelTests(unittest.TestCase):
    def test_samples_at_most_twelve_frames_and_three_per_speaker(self) -> None:
        turns = [
            {"speaker": f"incoming:SPEAKER_{speaker:02d}", "start": speaker * 20 + turn * 2, "end": speaker * 20 + turn * 2 + 1}
            for speaker in range(5)
            for turn in range(5)
        ]
        with self.fixture() as (video, helper):
            ffmpeg_timestamps: list[float] = []

            def run(command, **_kwargs):
                if command[0] == "/opt/homebrew/bin/ffmpeg":
                    ffmpeg_timestamps.append(float(command[command.index("-ss") + 1]))
                    Path(command[-1]).write_bytes(b"png")
                    return subprocess.CompletedProcess(command, 0, "", "")
                return subprocess.CompletedProcess(
                    command,
                    0,
                    json.dumps({"schema_version": 1, "frames": []}),
                    "",
                )

            with patch("meeting_archive_worker.visual_labels.shutil.which", return_value="/opt/homebrew/bin/ffmpeg"), \
                 patch("meeting_archive_worker.visual_labels.subprocess.run", side_effect=run):
                self.assertEqual(extract_visual_labels(video, turns, ["Alice Smith"], helper), {})

        self.assertEqual(len(ffmpeg_timestamps), 12)
        for speaker in range(5):
            own_range = [value for value in ffmpeg_timestamps if speaker * 20 <= value < (speaker + 1) * 20]
            self.assertLessEqual(len(own_range), 3)

    def test_retains_multiple_known_gallery_names_as_tentative_evidence(self) -> None:
        turns = [{"speaker": "incoming:SPEAKER_00", "start": 10.0, "end": 12.0}]
        with self.fixture() as (video, helper):
            def run(command, **_kwargs):
                if command[0] == "/opt/homebrew/bin/ffmpeg":
                    Path(command[-1]).write_bytes(b"png")
                    return subprocess.CompletedProcess(command, 0, "", "")
                frame = command[-1]
                payload = {
                    "schema_version": 1,
                    "frames": [{
                        "path": frame,
                        "observations": [
                            observation("Alice Smith", 0.94, 0.02),
                            observation("Bob Jones (Host)", 0.88, 0.27),
                            observation("Mike Cann’s Zoom Meeting", 0.99, 0.95),
                            observation("Welcome Alice Smith to the quarterly report", 0.97, 0.02),
                            observation("Mallory Adams", 0.99, 0.02),
                        ],
                    }],
                }
                return subprocess.CompletedProcess(command, 0, json.dumps(payload), "")

            with patch("meeting_archive_worker.visual_labels.shutil.which", return_value="/opt/homebrew/bin/ffmpeg"), \
                 patch("meeting_archive_worker.visual_labels.subprocess.run", side_effect=run):
                result = extract_visual_labels(
                    video,
                    turns,
                    ["Alice Smith", "Bob Jones", "Mike Cann"],
                    helper,
                )

        self.assertEqual(result, {
            "incoming:SPEAKER_00": [
                {"name": "Alice Smith", "timestamps": [11.0], "source": "video_label"},
                {"name": "Bob Jones", "timestamps": [11.0], "source": "video_label"},
            ],
        })

    def test_explicit_talking_cue_is_separate_evidence_and_rejects_prose(self) -> None:
        turns = [{"speaker": "incoming:SPEAKER_00", "start": 20.0, "end": 22.0}]
        with self.fixture() as (video, helper):
            def run(command, **_kwargs):
                if command[0] == "/opt/homebrew/bin/ffmpeg":
                    Path(command[-1]).write_bytes(b"png")
                    return subprocess.CompletedProcess(command, 0, "", "")
                payload = {
                    "schema_version": 1,
                    "frames": [{
                        "path": command[-1],
                        "observations": [
                            observation("Talking: Alice Smith", 0.96, 0.84),
                            observation("Speaking: Bob Jones!", 0.93, 0.48),
                            observation("Alice Smith is talking about the roadmap", 0.99, 0.02),
                            observation("Talking points: Mike Cann’s Zoom Meeting", 0.99, 0.94),
                        ],
                    }],
                }
                return subprocess.CompletedProcess(command, 0, json.dumps(payload), "")

            with patch("meeting_archive_worker.visual_labels.shutil.which", return_value="/opt/homebrew/bin/ffmpeg"), \
                 patch("meeting_archive_worker.visual_labels.subprocess.run", side_effect=run):
                result = extract_visual_labels(
                    video,
                    turns,
                    ["Alice Smith", "Bob Jones", "Mike Cann"],
                    helper,
                )

        self.assertEqual(result, {
            "incoming:SPEAKER_00": [
                {"name": "Alice Smith", "timestamps": [21.0], "source": "active_speaker_label"},
                {"name": "Bob Jones", "timestamps": [21.0], "source": "active_speaker_label"},
            ],
        })

    def test_accepts_real_zoom_label_just_above_toolbar_but_not_window_title(self) -> None:
        turns = [{"speaker": "microphone:SPEAKER_00", "start": 5.0, "end": 7.0}]
        with self.fixture() as (video, helper):
            def run(command, **_kwargs):
                if command[0] == "/opt/homebrew/bin/ffmpeg":
                    Path(command[-1]).write_bytes(b"png")
                    return subprocess.CompletedProcess(command, 0, "", "")
                payload = {
                    "schema_version": 1,
                    "frames": [{
                        "path": command[-1],
                        "observations": [
                            {
                                "text": "Mike Cann",
                                "confidence": 1,
                                "bounding_box": {
                                    "x": 0.02761628036,
                                    "y": 0.10555555584,
                                    "width": 0.05959302187,
                                    "height": 0.0212962963,
                                },
                            },
                            observation("Mike Cann’s Zoom Meeting", 1, 0.93796),
                        ],
                    }],
                }
                return subprocess.CompletedProcess(command, 0, json.dumps(payload), "")

            with patch("meeting_archive_worker.visual_labels.shutil.which", return_value="/opt/homebrew/bin/ffmpeg"), \
                 patch("meeting_archive_worker.visual_labels.subprocess.run", side_effect=run):
                result = extract_visual_labels(video, turns, ["Mike Cann"], helper)

        self.assertEqual(result, {
            "microphone:SPEAKER_00": [
                {"name": "Mike Cann", "timestamps": [6.0], "source": "video_label"},
            ],
        })

    def test_skips_failed_frames_and_rejects_non_label_geometry(self) -> None:
        turns = [
            {"speaker": "incoming:SPEAKER_00", "start": 0, "end": 2},
            {"speaker": "incoming:SPEAKER_00", "start": 4, "end": 6},
        ]
        with self.fixture() as (video, helper):
            extracted: list[str] = []

            def run(command, **_kwargs):
                if command[0] == "/opt/homebrew/bin/ffmpeg":
                    if len(extracted) == 0:
                        extracted.append(command[-1])
                        return subprocess.CompletedProcess(command, 1, "", "decode error")
                    Path(command[-1]).write_bytes(b"png")
                    extracted.append(command[-1])
                    return subprocess.CompletedProcess(command, 0, "", "")
                self.assertEqual(command[1:], [extracted[1]])
                payload = {
                    "schema_version": 1,
                    "frames": [{
                        "path": extracted[1],
                        "observations": [
                            observation("Alice Smith", 0.99, 0.18),
                            observation("Alice Smith", 0.30, 0.02),
                        ],
                    }],
                }
                return subprocess.CompletedProcess(command, 0, json.dumps(payload), "")

            with patch("meeting_archive_worker.visual_labels.shutil.which", return_value="/opt/homebrew/bin/ffmpeg"), \
                 patch("meeting_archive_worker.visual_labels.subprocess.run", side_effect=run):
                self.assertEqual(extract_visual_labels(video, turns, ["Alice Smith"], helper), {})

    def test_missing_tools_timeout_and_malformed_output_are_nonfatal(self) -> None:
        turns = [{"speaker": "incoming:SPEAKER_00", "start": 0, "end": 2}]
        with self.fixture() as (video, helper):
            with patch("meeting_archive_worker.visual_labels.shutil.which", return_value=None), \
                 patch("meeting_archive_worker.visual_labels.FFMPEG_FALLBACKS", ()), \
                 patch("meeting_archive_worker.visual_labels.subprocess.run") as run:
                self.assertEqual(extract_visual_labels(video, turns, ["Alice Smith"], helper), {})
                run.assert_not_called()

            def timeout(command, **_kwargs):
                if command[0] == "/opt/homebrew/bin/ffmpeg":
                    Path(command[-1]).write_bytes(b"png")
                    return subprocess.CompletedProcess(command, 0, "", "")
                raise subprocess.TimeoutExpired(command, 30)

            with patch("meeting_archive_worker.visual_labels.shutil.which", return_value="/opt/homebrew/bin/ffmpeg"), \
                 patch("meeting_archive_worker.visual_labels.subprocess.run", side_effect=timeout):
                self.assertEqual(extract_visual_labels(video, turns, ["Alice Smith"], helper), {})

            def malformed(command, **_kwargs):
                if command[0] == "/opt/homebrew/bin/ffmpeg":
                    Path(command[-1]).write_bytes(b"png")
                    return subprocess.CompletedProcess(command, 0, "", "")
                return subprocess.CompletedProcess(command, 0, "not json", "")

            with patch("meeting_archive_worker.visual_labels.shutil.which", return_value="/opt/homebrew/bin/ffmpeg"), \
                 patch("meeting_archive_worker.visual_labels.subprocess.run", side_effect=malformed):
                self.assertEqual(extract_visual_labels(video, turns, ["Alice Smith"], helper), {})

    def test_one_shared_deadline_stops_frame_work_before_helper(self) -> None:
        turns = [
            {"speaker": "incoming:SPEAKER_00", "start": 0, "end": 2},
            {"speaker": "incoming:SPEAKER_00", "start": 4, "end": 6},
            {"speaker": "incoming:SPEAKER_00", "start": 8, "end": 10},
        ]
        with self.fixture() as (video, helper):
            commands = []

            def run(command, **_kwargs):
                commands.append(command)
                Path(command[-1]).write_bytes(b"png")
                return subprocess.CompletedProcess(command, 0, "", "")

            with patch("meeting_archive_worker.visual_labels.shutil.which", return_value="/opt/homebrew/bin/ffmpeg"), \
                 patch("meeting_archive_worker.visual_labels.time.monotonic", side_effect=[0, 1, 21, 21]), \
                 patch("meeting_archive_worker.visual_labels.subprocess.run", side_effect=run):
                self.assertEqual(extract_visual_labels(video, turns, ["Alice Smith"], helper), {})

        self.assertEqual(len(commands), 1)
        self.assertEqual(commands[0][0], "/opt/homebrew/bin/ffmpeg")

    def test_uses_executable_regular_ffmpeg_fallback_when_path_omits_homebrew(self) -> None:
        turns = [{"speaker": "incoming:SPEAKER_00", "start": 0, "end": 2}]
        with self.fixture() as (video, helper):
            fallback = video.parent / "ffmpeg"
            fallback.write_text("fixture", encoding="utf-8")
            fallback.chmod(0o700)
            commands = []

            def run(command, **_kwargs):
                commands.append(command)
                if command[0] == str(fallback):
                    Path(command[-1]).write_bytes(b"png")
                    return subprocess.CompletedProcess(command, 0, "", "")
                return subprocess.CompletedProcess(
                    command, 0, json.dumps({"schema_version": 1, "frames": []}), "",
                )

            with patch("meeting_archive_worker.visual_labels.shutil.which", return_value=None), \
                 patch("meeting_archive_worker.visual_labels.FFMPEG_FALLBACKS", (fallback,)), \
                 patch("meeting_archive_worker.visual_labels.subprocess.run", side_effect=run):
                self.assertEqual(extract_visual_labels(video, turns, ["Alice Smith"], helper), {})

            self.assertEqual(commands[0][0], str(fallback))

            fallback.chmod(0o600)
            with patch("meeting_archive_worker.visual_labels.shutil.which", return_value=None), \
                 patch("meeting_archive_worker.visual_labels.FFMPEG_FALLBACKS", (fallback,)), \
                 patch("meeting_archive_worker.visual_labels.subprocess.run") as run:
                self.assertEqual(extract_visual_labels(video, turns, ["Alice Smith"], helper), {})
                run.assert_not_called()

    def test_rejects_single_token_candidates_and_helper_symlinks(self) -> None:
        turns = [{"speaker": "incoming:SPEAKER_00", "start": 0, "end": 2}]
        with self.fixture() as (video, helper):
            link = helper.parent / "linked-helper"
            link.symlink_to(helper)
            with patch("meeting_archive_worker.visual_labels.subprocess.run") as run:
                self.assertEqual(extract_visual_labels(video, turns, ["Alice"], helper), {})
                self.assertEqual(extract_visual_labels(video, turns, ["Alice Smith"], link), {})
                run.assert_not_called()

    class fixture:
        def __enter__(self):
            self.temporary = tempfile.TemporaryDirectory()
            root = Path(self.temporary.name)
            video = root / "meeting.mp4"
            video.write_bytes(b"video")
            helper = root / "vision-ocr"
            helper.write_text("helper", encoding="utf-8")
            helper.chmod(0o700)
            return video, helper

        def __exit__(self, *_args):
            self.temporary.cleanup()


def observation(text: str, confidence: float, y: float) -> dict[str, object]:
    return {
        "text": text,
        "confidence": confidence,
        "bounding_box": {"x": 0.1, "y": y, "width": 0.2, "height": 0.035},
    }


if __name__ == "__main__":
    unittest.main()
