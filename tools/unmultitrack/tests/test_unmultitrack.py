import importlib.util
import pathlib
import sys
import tempfile
import unittest


TOOL_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOL_DIR / "unmultitrack.py"


def load_module():
    spec = importlib.util.spec_from_file_location("unmultitrack", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules["unmultitrack"] = module
    spec.loader.exec_module(module)
    return module


class UnmultitrackTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_parse_ffmpeg_streams_handles_obs_multitrack_output(self):
        ffmpeg_output = """
Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'clip.mp4':
  Stream #0:0[0x1](und): Video: av1 (Main) (av01 / 0x31307661), yuv420p(tv, bt709), 3840x2160, 30 fps (default)
  Stream #0:1[0x2](und): Video: av1 (Main) (av01 / 0x31307661), yuv420p(tv, bt709), 3840x2160, 30 fps (default)
  Stream #0:2[0x3](und): Audio: aac (LC) (mp4a / 0x6134706D), 48000 Hz, stereo, fltp, 127 kb/s (default)
"""

        streams = self.module.parse_ffmpeg_streams(ffmpeg_output)

        self.assertEqual(["video", "video", "audio"], [stream.kind for stream in streams])
        self.assertEqual([0, 1, 2], [stream.input_index for stream in streams])
        self.assertEqual("av1 (Main) (av01 / 0x31307661)", streams[0].codec)
        self.assertEqual("aac (LC) (mp4a / 0x6134706D)", streams[2].codec)

    def test_parse_ffprobe_json_reads_video_and_audio_streams(self):
        payload = {
            "streams": [
                {"index": 0, "codec_type": "video", "codec_name": "av1"},
                {"index": 1, "codec_type": "video", "codec_name": "av1"},
                {"index": 2, "codec_type": "audio", "codec_name": "aac"},
            ],
        }

        streams = self.module.streams_from_ffprobe_json(payload)

        self.assertEqual(["video", "video", "audio"], [stream.kind for stream in streams])
        self.assertEqual("av1", streams[0].codec)

    def test_default_output_dir_sits_next_to_input(self):
        input_path = pathlib.Path(r"C:\videos\clip.mp4")

        output_dir = self.module.default_output_dir(input_path)

        self.assertEqual(pathlib.Path(r"C:\videos\clip_unmultitracked"), output_dir)

    def test_output_plan_avoids_overwriting_existing_tracks(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = pathlib.Path(temp_dir)
            input_path = temp_path / "clip.mp4"
            output_dir = temp_path / "clip_unmultitracked"
            output_dir.mkdir()
            (output_dir / "clip_v1.mp4").write_bytes(b"existing")

            jobs = self.module.build_output_plan(
                ffmpeg=pathlib.Path(r"C:\dev\tools\ffmpeg.exe"),
                input_path=input_path,
                streams=[
                    self.module.StreamInfo(input_index=0, kind="video", codec="av1"),
                    self.module.StreamInfo(input_index=1, kind="video", codec="av1"),
                    self.module.StreamInfo(input_index=2, kind="audio", codec="aac"),
                ],
                output_dir=output_dir,
                include_audio=True,
                overwrite=False,
            )

            self.assertEqual("clip_v1_2.mp4", jobs[0].output_path.name)
            self.assertEqual("clip_v2.mp4", jobs[1].output_path.name)

    def test_output_plan_rejects_single_video_stream_by_default(self):
        with self.assertRaises(ValueError):
            self.module.build_output_plan(
                ffmpeg=pathlib.Path(r"C:\dev\tools\ffmpeg.exe"),
                input_path=pathlib.Path("clip.mp4"),
                streams=[self.module.StreamInfo(input_index=0, kind="video", codec="h264")],
                allow_single=False,
            )

    def test_build_demux_command_maps_one_video_and_all_audio(self):
        command = self.module.build_demux_command(
            ffmpeg=pathlib.Path(r"C:\dev\tools\ffmpeg.exe"),
            input_path=pathlib.Path("input.mp4"),
            video_position=1,
            output_path=pathlib.Path("output.mp4"),
            include_audio=True,
            overwrite=False,
        )

        self.assertIn("-n", command)
        self.assertIn("0:v:1", command)
        self.assertIn("0:a?", command)
        self.assertIn("+faststart", command)
        self.assertEqual("output.mp4", command[-1])

    def test_build_demux_command_can_skip_audio(self):
        command = self.module.build_demux_command(
            ffmpeg=pathlib.Path(r"C:\dev\tools\ffmpeg.exe"),
            input_path=pathlib.Path("input.mkv"),
            video_position=0,
            output_path=pathlib.Path("output.mkv"),
            include_audio=False,
            overwrite=True,
        )

        self.assertIn("-y", command)
        self.assertNotIn("0:a?", command)
        self.assertNotIn("+faststart", command)


if __name__ == "__main__":
    unittest.main()
