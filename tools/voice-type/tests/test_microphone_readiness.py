import importlib.util
import pathlib
import sys
import unittest
from unittest import mock

import numpy as np


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOLS_DIR / "microphone_readiness.py"


def load_module():
    spec = importlib.util.spec_from_file_location("microphone_readiness", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class FakeStream:
    def __init__(self, callback, samples):
        self.callback = callback
        self.samples = samples
        self.started = False
        self.stopped = False
        self.closed = False

    def start(self):
        self.started = True
        self.callback(self.samples, len(self.samples), None, None)

    def stop(self):
        self.stopped = True

    def close(self):
        self.closed = True


class MicrophoneReadinessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_resolves_configured_microphone_instead_of_system_default(self):
        sounddevice = mock.Mock()
        sounddevice.query_devices.return_value = [
            {"name": "MacBook Pro Microphone", "max_input_channels": 1},
            {"name": "Yeti Stereo Microphone", "max_input_channels": 2},
        ]

        selected = self.module.resolve_input_device(
            sounddevice,
            "Yeti Stereo Microphone",
        )

        self.assertEqual(selected.index, 1)
        self.assertEqual(selected.name, "Yeti Stereo Microphone")

    def test_missing_configured_microphone_is_not_replaced_by_default(self):
        sounddevice = mock.Mock()
        sounddevice.query_devices.return_value = [
            {"name": "MacBook Pro Microphone", "max_input_channels": 1},
        ]

        with self.assertRaisesRegex(
            self.module.MicrophoneUnavailable,
            "Yeti Stereo Microphone",
        ):
            self.module.resolve_input_device(sounddevice, "Yeti Stereo Microphone")

    def test_preferred_microphone_is_checked_during_resume_grace_period(self):
        self.assertEqual(
            self.module.microphone_candidate(
                preferred_name="Yeti Stereo Microphone",
                elapsed_seconds=29.9,
                preferred_wait_seconds=30.0,
            ),
            "Yeti Stereo Microphone",
        )

    def test_system_default_is_used_after_preferred_microphone_grace_period(self):
        self.assertIsNone(
            self.module.microphone_candidate(
                preferred_name="Yeti Stereo Microphone",
                elapsed_seconds=30.0,
                preferred_wait_seconds=30.0,
            )
        )

    def test_system_default_is_used_immediately_when_no_preference_is_configured(self):
        self.assertIsNone(
            self.module.microphone_candidate(
                preferred_name="",
                elapsed_seconds=0.0,
                preferred_wait_seconds=30.0,
            )
        )

    def test_probe_accepts_a_live_configured_microphone(self):
        samples = np.full((800, 1), 0.002, dtype=np.float32)
        stream_holder = []
        sounddevice = mock.Mock()
        sounddevice.query_devices.return_value = [
            {"name": "Yeti Stereo Microphone", "max_input_channels": 2},
        ]

        def input_stream(**kwargs):
            stream = FakeStream(kwargs["callback"], samples)
            stream_holder.append((stream, kwargs))
            return stream

        sounddevice.InputStream.side_effect = input_stream

        result = self.module.probe_input_device(
            sounddevice,
            preferred_name="Yeti Stereo Microphone",
            sample_rate=16000,
            channels=1,
            dtype="float32",
            duration_seconds=0.05,
            sleep=lambda _seconds: None,
        )

        stream, kwargs = stream_holder[0]
        self.assertTrue(result.ready)
        self.assertEqual(result.device.name, "Yeti Stereo Microphone")
        self.assertEqual(kwargs["device"], 0)
        self.assertTrue(stream.started)
        self.assertTrue(stream.stopped)
        self.assertTrue(stream.closed)

    def test_probe_rejects_digital_zero_before_dictation_is_enabled(self):
        samples = np.zeros((800, 1), dtype=np.float32)
        sounddevice = mock.Mock()
        sounddevice.query_devices.return_value = [
            {"name": "Yeti Stereo Microphone", "max_input_channels": 2},
        ]
        sounddevice.InputStream.side_effect = lambda **kwargs: FakeStream(
            kwargs["callback"], samples
        )

        result = self.module.probe_input_device(
            sounddevice,
            preferred_name="Yeti Stereo Microphone",
            sample_rate=16000,
            channels=1,
            dtype="float32",
            duration_seconds=0.05,
            sleep=lambda _seconds: None,
        )

        self.assertFalse(result.ready)
        self.assertEqual(result.reason, "digital silence")

    def test_refresh_reinitializes_portaudio_device_state(self):
        sounddevice = mock.Mock()

        self.module.refresh_audio_devices(sounddevice)

        sounddevice._terminate.assert_called_once_with()
        sounddevice._initialize.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
