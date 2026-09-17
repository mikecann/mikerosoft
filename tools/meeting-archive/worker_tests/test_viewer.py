from __future__ import annotations

import http.client
import json
import os
import shutil
import sqlite3
import tempfile
import threading
import unittest
import uuid
from contextlib import closing
from pathlib import Path

from meeting_archive_worker.viewer import create_server


ALLOWED_LOGIN = "mike.cann@gmail.com"


class ViewerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.archive_root = self.root / "meetings"
        self.archive_root.mkdir()
        self.database = self.root / "worker.sqlite"
        self.meeting_id = str(uuid.uuid4())
        self.archive = self.archive_root / "2026" / "09" / self.meeting_id
        (self.archive / "playback").mkdir(parents=True)
        (self.archive / "transcripts" / "v1").mkdir(parents=True)
        self.media = bytes(range(64))
        (self.archive / "playback" / "meeting.mp4").write_bytes(self.media)
        (self.archive / "metadata.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "meeting_id": self.meeting_id,
                    "manifest_revision": 1,
                    "title": "Planning <img src=x onerror=alert(1)>",
                    "started_at": "2026-09-17T08:00:00Z",
                    "ended_at": "2026-09-17T08:17:00Z",
                    "duration_seconds": 17,
                    "timezone": "Australia/Perth",
                }
            ),
            encoding="utf-8",
        )
        transcript = {
            "meeting_id": self.meeting_id,
            "manifest_revision": 1,
            "turns": [
                {
                    "start": 1.25,
                    "end": 2.5,
                    "speaker": "incoming:SPEAKER_00",
                    "name": "Alice <Admin>",
                    "channel_origin": "incoming",
                    "text": "Hello <script>alert('x')</script>",
                }
            ],
        }
        transcript_directory = self.archive / "transcripts" / "v1"
        (transcript_directory / "transcript.json").write_text(
            json.dumps(transcript), encoding="utf-8"
        )
        (transcript_directory / "transcript.md").write_text(
            "# Transcript\n\n- Alice: Hello <script>alert('x')</script>\n",
            encoding="utf-8",
        )
        self._create_acceptance(self.meeting_id, self.archive)
        self.server = create_server(
            archive_root=self.archive_root,
            database=self.database,
            host="127.0.0.1",
            port=0,
            allowed_login=ALLOWED_LOGIN,
            max_threads=2,
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.temporary.cleanup()

    def _create_acceptance(
        self,
        meeting_id: str,
        archive: Path,
        *,
        acknowledgement_meeting_id: str | None = None,
        revision: int = 1,
    ) -> None:
        acknowledgement = {
            "schema_version": 1,
            "meeting_id": acknowledgement_meeting_id or meeting_id,
            "manifest_revision": revision,
            "manifest_sha256": "a" * 64,
            "archive_path": str(archive),
            "accepted_at": "2026-09-17T08:18:00Z",
            "verified_files": [],
            "queue_job_id": "1",
            "cleanup_allowed": True,
        }
        with closing(sqlite3.connect(self.database)) as connection:
            with connection:
                connection.execute(
                    """CREATE TABLE IF NOT EXISTS acceptances (
                    meeting_id TEXT PRIMARY KEY,
                    manifest_revision INTEGER NOT NULL,
                    manifest_sha256 TEXT NOT NULL,
                    archive_path TEXT NOT NULL,
                    acknowledgement_json TEXT NOT NULL,
                    accepted_at TEXT NOT NULL)"""
                )
                connection.execute(
                    "INSERT OR REPLACE INTO acceptances VALUES (?, ?, ?, ?, ?, ?)",
                    (
                        meeting_id,
                        revision,
                        "a" * 64,
                        str(archive),
                        json.dumps(acknowledgement),
                        "2026-09-17T08:18:00Z",
                    ),
                )

    def _request(
        self,
        path: str,
        *,
        method: str = "GET",
        headers: dict[str, str] | None = None,
    ) -> tuple[int, dict[str, str], bytes]:
        request_headers = {"Tailscale-User-Login": ALLOWED_LOGIN}
        if headers is not None:
            request_headers.update(headers)
        connection = http.client.HTTPConnection(
            "127.0.0.1", self.server.server_address[1], timeout=5
        )
        try:
            connection.request(method, path, headers=request_headers)
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def test_landing_page_is_private_escaped_and_has_seek_and_app_controls(self) -> None:
        status, headers, body = self._request(f"/meeting/{self.meeting_id}")

        self.assertEqual(status, 200)
        page = body.decode("utf-8")
        self.assertIn("Planning &lt;img src=x onerror=alert(1)&gt;", page)
        self.assertIn("Alice &lt;Admin&gt;", page)
        self.assertIn("Hello &lt;script&gt;alert(&#x27;x&#x27;)&lt;/script&gt;", page)
        self.assertNotIn("<script>alert('x')</script>", page)
        self.assertIn(f'meetingarchive://meeting/{self.meeting_id}', page)
        self.assertIn(f'/meeting/{self.meeting_id}/playback.mp4', page)
        self.assertIn('id="transcript"', page)
        self.assertIn('href="#t=1.250"', page)
        self.assertIn("00:00:01", page)
        self.assertIn("new URLSearchParams(location.hash.slice(1))", page)
        self.assertIn("if(link.hash===location.hash)", page)
        self.assertIn("event.preventDefault();seekFromHash();", page)
        self.assertIn("17 Sep 2026", page)
        self.assertIn("17 seconds", page)
        self.assertIn("<style nonce=", page)
        self.assertIn("default-src 'none'", headers["Content-Security-Policy"])
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        self.assertEqual(headers["Cache-Control"], "private, no-store")

    def test_landing_page_gives_unnamed_speakers_stable_natural_labels(self) -> None:
        transcript_path = self.archive / "transcripts" / "v1" / "transcript.json"
        transcript_path.write_text(
            json.dumps(
                {
                    "meeting_id": self.meeting_id,
                    "manifest_revision": 1,
                    "turns": [
                        {
                            "start": 1.0,
                            "end": 2.0,
                            "speaker": "microphone:SPEAKER_00",
                            "channel_origin": "microphone",
                            "text": "First",
                        },
                        {
                            "start": 2.0,
                            "end": 3.0,
                            "speaker": "incoming:SPEAKER_00",
                            "channel_origin": "incoming",
                            "text": "Second",
                        },
                        {
                            "start": 3.0,
                            "end": 4.0,
                            "speaker": "microphone:SPEAKER_00",
                            "channel_origin": "microphone",
                            "text": "Third",
                        },
                    ],
                }
            ),
            encoding="utf-8",
        )

        status, _, body = self._request(f"/meeting/{self.meeting_id}")

        self.assertEqual(status, 200)
        page = body.decode("utf-8")
        self.assertEqual(page.count("Unknown speaker 1 (microphone)"), 2)
        self.assertEqual(page.count("Unknown speaker 2 (incoming)"), 1)
        self.assertNotIn("microphone:SPEAKER_00", page)
        self.assertNotIn("incoming:SPEAKER_00", page)

    def test_requires_exact_single_tailscale_identity(self) -> None:
        connection = http.client.HTTPConnection(
            "127.0.0.1", self.server.server_address[1], timeout=5
        )
        try:
            connection.request("GET", f"/meeting/{self.meeting_id}")
            response = connection.getresponse()
            self.assertEqual(response.status, 401)
            response.read()
        finally:
            connection.close()

        status, _, _ = self._request(
            f"/meeting/{self.meeting_id}",
            headers={"Tailscale-User-Login": "somebody@example.com"},
        )
        self.assertEqual(status, 403)

        connection = http.client.HTTPConnection(
            "127.0.0.1", self.server.server_address[1], timeout=5
        )
        try:
            connection.putrequest("GET", f"/meeting/{self.meeting_id}")
            connection.putheader("Tailscale-User-Login", ALLOWED_LOGIN)
            connection.putheader("Tailscale-User-Login", ALLOWED_LOGIN)
            connection.endheaders()
            response = connection.getresponse()
            self.assertEqual(response.status, 403)
            self.assertEqual(response.read(), b"")
        finally:
            connection.close()

        connection = http.client.HTTPConnection(
            "127.0.0.1", self.server.server_address[1], timeout=5
        )
        try:
            connection.request("POST", f"/meeting/{self.meeting_id}")
            response = connection.getresponse()
            self.assertEqual(response.status, 401)
            self.assertEqual(response.read(), b"")
        finally:
            connection.close()

        connection = http.client.HTTPConnection(
            "127.0.0.1", self.server.server_address[1], timeout=5
        )
        try:
            connection.request("PROPFIND", f"/meeting/{self.meeting_id}")
            response = connection.getresponse()
            self.assertEqual(response.status, 401)
            self.assertEqual(response.read(), b"")
        finally:
            connection.close()

    def test_valid_media_full_get_and_head(self) -> None:
        path = f"/meeting/{self.meeting_id}/playback.mp4"
        status, headers, body = self._request(path)
        self.assertEqual(status, 200)
        self.assertEqual(body, self.media)
        self.assertEqual(headers["Content-Type"], "video/mp4")
        self.assertEqual(headers["Content-Length"], str(len(self.media)))
        self.assertEqual(headers["Accept-Ranges"], "bytes")

        status, headers, body = self._request(path, method="HEAD")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"")
        self.assertEqual(headers["Content-Length"], str(len(self.media)))

    def test_safe_single_ranges(self) -> None:
        path = f"/meeting/{self.meeting_id}/playback.mp4"
        cases = [
            ("bytes=2-5", self.media[2:6], "bytes 2-5/64"),
            ("bytes=60-", self.media[60:], "bytes 60-63/64"),
            ("bytes=-4", self.media[-4:], "bytes 60-63/64"),
        ]
        for value, expected, content_range in cases:
            with self.subTest(value=value):
                status, headers, body = self._request(path, headers={"Range": value})
                self.assertEqual(status, 206)
                self.assertEqual(body, expected)
                self.assertEqual(headers["Content-Range"], content_range)
                self.assertEqual(headers["Content-Length"], str(len(expected)))

        status, headers, body = self._request(
            path, method="HEAD", headers={"Range": "bytes=2-5"}
        )
        self.assertEqual(status, 206)
        self.assertEqual(body, b"")
        self.assertEqual(headers["Content-Range"], "bytes 2-5/64")

    def test_rejects_range_abuse(self) -> None:
        path = f"/meeting/{self.meeting_id}/playback.mp4"
        for value in (
            "bytes=0-1,3-4",
            "bytes=999-1000",
            "bytes=5-2",
            "bytes=-0",
            "items=0-1",
            "bytes=" + "1" * 200 + "-",
        ):
            with self.subTest(value=value):
                status, headers, body = self._request(path, headers={"Range": value})
                self.assertEqual(status, 416)
                self.assertEqual(headers["Content-Range"], "bytes */64")
                self.assertEqual(body, b"")

        connection = http.client.HTTPConnection(
            "127.0.0.1", self.server.server_address[1], timeout=5
        )
        try:
            connection.putrequest("GET", path)
            connection.putheader("Tailscale-User-Login", ALLOWED_LOGIN)
            connection.putheader("Range", "bytes=0-1")
            connection.putheader("Range", "bytes=3-4")
            connection.endheaders()
            response = connection.getresponse()
            self.assertEqual(response.status, 416)
            self.assertEqual(response.getheader("Content-Range"), "bytes */64")
            self.assertEqual(response.read(), b"")
        finally:
            connection.close()

    def test_transcript_markdown_is_a_fixed_non_html_resource(self) -> None:
        status, headers, body = self._request(
            f"/meeting/{self.meeting_id}/transcript.md"
        )
        self.assertEqual(status, 200)
        self.assertEqual(headers["Content-Type"], "text/markdown; charset=utf-8")
        self.assertIn(b"<script>", body)
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")

    def test_rejects_missing_ids_traversal_queries_and_arbitrary_files(self) -> None:
        (self.archive / "secret.txt").write_text("do not serve", encoding="utf-8")
        missing = str(uuid.uuid4())
        for path in (
            "/",
            "/meeting/not-a-uuid",
            f"/meeting/{missing}",
            f"/meeting/{self.meeting_id}/../metadata.json",
            f"/meeting/{self.meeting_id}/%2e%2e/metadata.json",
            f"/meeting/{self.meeting_id}/secret.txt",
            f"/meeting/{self.meeting_id}?path=metadata.json",
        ):
            with self.subTest(path=path):
                status, _, body = self._request(path)
                self.assertEqual(status, 404)
                self.assertEqual(body, b"")

    def test_rejects_acceptance_outside_archive_root(self) -> None:
        outside = self.root / "outside" / "2026" / "09" / self.meeting_id
        shutil.copytree(self.archive, outside)
        self._create_acceptance(self.meeting_id, outside)

        status, _, body = self._request(f"/meeting/{self.meeting_id}")
        self.assertEqual(status, 404)
        self.assertEqual(body, b"")

    @unittest.skipUnless(hasattr(os, "symlink"), "symlinks are unavailable")
    def test_rejects_symlinked_generated_file_and_parent(self) -> None:
        external = self.root / "external.mp4"
        external.write_bytes(self.media)
        playback = self.archive / "playback" / "meeting.mp4"
        playback.unlink()
        playback.symlink_to(external)

        status, _, body = self._request(
            f"/meeting/{self.meeting_id}/playback.mp4"
        )
        self.assertEqual(status, 404)
        self.assertEqual(body, b"")

        playback.unlink()
        playback.write_bytes(self.media)
        real_transcripts = self.archive / "real-transcripts"
        (self.archive / "transcripts").rename(real_transcripts)
        (self.archive / "transcripts").symlink_to(real_transcripts)
        status, _, body = self._request(f"/meeting/{self.meeting_id}")
        self.assertEqual(status, 404)
        self.assertEqual(body, b"")

    @unittest.skipUnless(hasattr(os, "symlink"), "symlinks are unavailable")
    def test_rejects_acceptance_path_with_symlink_loop_without_dropping_connection(self) -> None:
        other_id = str(uuid.uuid4())
        loop = self.archive_root / "loop"
        loop.symlink_to(loop)
        self._create_acceptance(other_id, loop / "09" / other_id)

        status, _, body = self._request(f"/meeting/{other_id}")
        self.assertEqual(status, 404)
        self.assertEqual(body, b"")

    @unittest.skipUnless(hasattr(os, "symlink"), "symlinks are unavailable")
    def test_rejects_in_root_symlink_in_accepted_archive_components(self) -> None:
        other_id = str(uuid.uuid4())
        other_archive = self.archive_root / "2026" / "09" / other_id
        shutil.copytree(self.archive, other_archive)
        (self.archive_root / "2025").symlink_to(self.archive_root / "2026")
        accepted_path = self.archive_root / "2025" / "09" / other_id
        self._create_acceptance(other_id, accepted_path)

        status, _, body = self._request(f"/meeting/{other_id}/playback.mp4")
        self.assertEqual(status, 404)
        self.assertEqual(body, b"")

    def test_rejects_dotdot_even_when_lexical_path_would_land_in_root(self) -> None:
        raw_path = self.archive_root / "extra" / ".." / "2026" / "09" / self.meeting_id
        self._create_acceptance(self.meeting_id, raw_path)

        status, _, body = self._request(f"/meeting/{self.meeting_id}")
        self.assertEqual(status, 404)
        self.assertEqual(body, b"")

    def test_rejects_tampered_acceptance_identity(self) -> None:
        self._create_acceptance(
            self.meeting_id,
            self.archive,
            acknowledgement_meeting_id=str(uuid.uuid4()),
        )

        status, _, body = self._request(f"/meeting/{self.meeting_id}")
        self.assertEqual(status, 404)
        self.assertEqual(body, b"")

    def test_rejects_non_text_acceptance_path_without_dropping_connection(self) -> None:
        with closing(sqlite3.connect(self.database)) as connection:
            with connection:
                acknowledgement = json.loads(
                    connection.execute(
                        "SELECT acknowledgement_json FROM acceptances WHERE meeting_id=?",
                        (self.meeting_id,),
                    ).fetchone()[0]
                )
                acknowledgement["archive_path"] = 123
                connection.execute(
                    "UPDATE acceptances SET archive_path=?, acknowledgement_json=? WHERE meeting_id=?",
                    (123, json.dumps(acknowledgement), self.meeting_id),
                )

        status, _, body = self._request(f"/meeting/{self.meeting_id}")
        self.assertEqual(status, 404)
        self.assertEqual(body, b"")

    def test_rejects_metadata_from_another_meeting_or_revision(self) -> None:
        metadata_path = self.archive / "metadata.json"
        metadata = json.loads(metadata_path.read_text())
        for key, value in (
            ("meeting_id", str(uuid.uuid4())),
            ("manifest_revision", 2),
        ):
            with self.subTest(key=key):
                changed = dict(metadata)
                changed[key] = value
                metadata_path.write_text(json.dumps(changed), encoding="utf-8")
                status, _, body = self._request(f"/meeting/{self.meeting_id}")
                self.assertEqual(status, 404)
                self.assertEqual(body, b"")

    def test_requests_do_not_mutate_archive_or_database(self) -> None:
        before_files = sorted(
            str(path.relative_to(self.root)) for path in self.root.rglob("*")
        )
        before_database = self.database.read_bytes()
        before_media = (self.archive / "playback" / "meeting.mp4").read_bytes()

        status, _, _ = self._request(f"/meeting/{self.meeting_id}")
        self.assertEqual(status, 200)

        self.assertEqual(before_database, self.database.read_bytes())
        self.assertEqual(before_media, (self.archive / "playback" / "meeting.mp4").read_bytes())
        self.assertEqual(
            before_files,
            sorted(str(path.relative_to(self.root)) for path in self.root.rglob("*")),
        )

    def test_rejects_oversized_metadata_before_reading_it_into_memory(self) -> None:
        (self.archive / "metadata.json").write_bytes(b"x" * (1024 * 1024 + 1))

        status, _, body = self._request(f"/meeting/{self.meeting_id}")
        self.assertEqual(status, 413)
        self.assertEqual(body, b"")

    def test_server_is_localhost_only_and_bounds_threads(self) -> None:
        self.assertEqual(self.server.server_address[0], "127.0.0.1")
        self.assertEqual(self.server.max_threads, 2)
        self.assertLessEqual(self.server.request_timeout_seconds, 30)
        with self.assertRaisesRegex(ValueError, "only to 127.0.0.1"):
            create_server(
                archive_root=self.archive_root,
                database=self.database,
                host="0.0.0.0",
                port=0,
                allowed_login=ALLOWED_LOGIN,
            )


class ViewerScriptTests(unittest.TestCase):
    def test_installer_is_staged_by_default_and_never_mutates_tailscale(self) -> None:
        root = Path(__file__).parents[1] / "worker"
        installer = (root / "install-viewer-service-bruce.sh").read_text()
        wrapper = (root / "run-viewer-bruce.sh").read_text()

        self.assertIn('case "${1:-}"', installer)
        self.assertIn("--enable", installer)
        self.assertIn('/bin/chmod 600 "${temporary}"', installer)
        self.assertNotIn("tailscale serve", installer)
        self.assertIn("5CCB1D81-5A98-4C4A-9E2C-3E10B23F1B46", wrapper)
        self.assertIn("127.0.0.1", wrapper)
        self.assertIn("8765", wrapper)
        self.assertIn(ALLOWED_LOGIN, wrapper)


if __name__ == "__main__":
    unittest.main()
