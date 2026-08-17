import pathlib
import sys
import threading
import time
import unittest


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS_DIR))

from inference_scheduler import InferenceScheduler, should_request_precompute


class InferenceSchedulerTests(unittest.TestCase):
    def test_first_precompute_uses_minimum_audio_then_later_passes_use_delta(self):
        minimum = 250
        delta = 400

        self.assertFalse(
            should_request_precompute(249, 0, minimum, delta)
        )
        self.assertTrue(
            should_request_precompute(250, 0, minimum, delta)
        )
        self.assertFalse(
            should_request_precompute(649, 250, minimum, delta)
        )
        self.assertTrue(
            should_request_precompute(650, 250, minimum, delta)
        )

    def test_background_transcription_materializes_lazy_segments_while_locked(self):
        scheduler = InferenceScheduler()
        events = []
        info = object()

        def lazy_segments():
            events.append("decode-start")
            yield "first"
            events.append("decode-end")

        ran, result = scheduler.run_background_transcription(
            "preview",
            lambda: (lazy_segments(), info),
        )

        self.assertTrue(ran)
        self.assertEqual((["first"], info), result)
        self.assertEqual(["decode-start", "decode-end"], events)

    def test_final_transcription_materializes_lazy_segments_while_locked(self):
        scheduler = InferenceScheduler()
        events = []
        info = object()

        class Segment:
            text = "final"

        def lazy_segments():
            events.append("decode-start")
            yield Segment()
            events.append("after-yield")
            events.append("decode-end")

        segments, returned_info = scheduler.run_final_transcription(
            lambda: (lazy_segments(), info),
            on_segment=lambda text: events.append(f"callback-{text}"),
        )

        self.assertEqual("final", segments[0].text)
        self.assertIs(info, returned_info)
        self.assertEqual(
            ["decode-start", "callback-final", "after-yield", "decode-end"],
            events,
        )

    def test_jobs_never_overlap(self):
        scheduler = InferenceScheduler()
        first_started = threading.Event()
        release_first = threading.Event()
        events = []

        def first_job():
            events.append("first-start")
            first_started.set()
            release_first.wait(timeout=1)
            events.append("first-end")

        def second_job():
            events.append("second-start")

        first = threading.Thread(
            target=lambda: scheduler.run_background("preview", first_job)
        )
        second = threading.Thread(
            target=lambda: scheduler.run_background("precompute", second_job)
        )
        first.start()
        self.assertTrue(first_started.wait(timeout=1))
        second.start()
        time.sleep(0.03)

        self.assertEqual(["first-start"], events)

        release_first.set()
        first.join(timeout=1)
        second.join(timeout=1)
        self.assertEqual(
            ["first-start", "first-end", "second-start"],
            events,
        )

    def test_key_up_skips_queued_background_work_and_prioritizes_final(self):
        scheduler = InferenceScheduler()
        active_started = threading.Event()
        release_active = threading.Event()
        events = []

        def active_background():
            events.append("active-start")
            active_started.set()
            release_active.wait(timeout=1)
            events.append("active-end")

        active = threading.Thread(
            target=lambda: scheduler.run_background("precompute", active_background)
        )
        active.start()
        self.assertTrue(active_started.wait(timeout=1))

        scheduler.request_finalization()
        ran_preview, _ = scheduler.run_background(
            "preview", lambda: events.append("stale-preview")
        )
        ran_precompute, _ = scheduler.run_background(
            "precompute", lambda: events.append("stale-precompute")
        )
        final = threading.Thread(
            target=lambda: scheduler.run_final(lambda: events.append("final"))
        )
        final.start()
        time.sleep(0.03)

        self.assertFalse(ran_preview)
        self.assertFalse(ran_precompute)
        self.assertNotIn("final", events)

        release_active.set()
        active.join(timeout=1)
        final.join(timeout=1)
        self.assertEqual(["active-start", "active-end", "final"], events)

    def test_background_work_resumes_after_finalization(self):
        scheduler = InferenceScheduler()
        scheduler.request_finalization()
        scheduler.run_final(lambda: None)

        ran, value = scheduler.run_background("preview", lambda: "preview")

        self.assertTrue(ran)
        self.assertEqual("preview", value)


if __name__ == "__main__":
    unittest.main()
