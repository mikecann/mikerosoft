# Meeting label OCR helper

This local macOS helper runs Apple Vision text recognition on up to 12 PNG
frames and returns compact JSON containing recognized text, confidence, and
normalized bounding boxes. It makes no network requests and performs no face
recognition.

Build it on Bruce with:

```sh
bash vision/build.sh
```

The binary is written to `vision/meeting-label-ocr`, which is the default path
used by `meeting_archive_worker.visual_labels`. The Python adapter extracts
bounded frames with ffmpeg and only retains full names supplied by its caller.
Names visible together in a gallery remain multiple tentative evidence labels;
they never become automatic speaker assignments.

The adapter also recognizes exact local UI cues such as `Talking: Mike Cann`
or `Speaking: Mike Cann`. These are returned as `active_speaker_label`
evidence, still tentative and never an identity assignment. Generic prose and
window titles are rejected. No pixel-border or face inference is attempted.

Run the helper contract tests with:

```sh
bash vision/run-tests.sh
```

Set `MEETING_ARCHIVE_VISION_OCR_FIXTURE` to a local PNG to add an actual Vision
OCR smoke test. The fixture is optional because OCR results depend on the host
OS. Python subprocess, timeout, frame-budget, matching, and failure behavior is
covered by `worker_tests/test_visual_labels.py`.
