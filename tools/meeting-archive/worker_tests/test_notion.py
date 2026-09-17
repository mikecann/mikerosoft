from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from urllib.parse import urlparse


WORKER_ROOT = Path(__file__).resolve().parents[1] / "worker"
sys.path.insert(0, str(WORKER_ROOT))

from meeting_archive_worker.notion import publish as publish_archive  # noqa: E402


PLAYBACK_BASE = "https://bruce.example.ts.net:8448/meeting-archive"


def publish(*args, **kwargs):
    kwargs.setdefault("playback_base_url", PLAYBACK_BASE)
    return publish_archive(*args, **kwargs)


class MockTransport:
    def __init__(self) -> None:
        self.calls: list[tuple[str, str, dict]] = []
        self.pages: list[dict] = []
        self.children: dict[str, list[dict]] = {}
        self.fail_create_once = False
        self.fail_append_once = False
        self.rate_limit_once = False

    def __call__(self, request):
        method = request.method or "GET"
        parsed = urlparse(request.full_url)
        path = parsed.path.removeprefix("/v1/")
        body = json.loads(request.data.decode()) if request.data else {}
        self.calls.append((method, path, body))

        if self.rate_limit_once and method == "POST" and path.endswith("/query"):
            self.rate_limit_once = False
            return 429, {"Retry-After": "0"}, {"message": "slow down"}

        if method == "POST" and path == "pages":
            page = {
                "object": "page",
                "id": "page-1",
                "url": "https://notion.local/page-1",
                "properties": body["properties"],
            }
            self.pages.append(page)
            if self.fail_create_once:
                self.fail_create_once = False
                raise OSError("connection reset after create")
            return 200, {}, page
        if method == "POST" and path.startswith("data_sources/") and path.endswith("/query"):
            return 200, {}, {"results": self.pages, "has_more": False, "next_cursor": None}
        if method == "PATCH" and path.startswith("blocks/") and path.endswith("/children"):
            page_id = path.split("/")[1]
            blocks = []
            for block in body["children"]:
                block = dict(block)
                block["id"] = f"block-{len(self.children.get(page_id, [])) + len(blocks) + 1}"
                blocks.append(block)
            self.children.setdefault(page_id, []).extend(blocks)
            if self.fail_append_once:
                self.fail_append_once = False
                raise OSError("connection reset after append")
            return 200, {}, {"results": blocks, "has_more": False}
        if method == "GET" and path.startswith("blocks/") and path.endswith("/children"):
            page_id = path.split("/")[1]
            return 200, {}, {"results": self.children.get(page_id, []), "has_more": False}
        if method == "PATCH" and path.startswith("blocks/"):
            block_id = path.split("/")[1]
            for block in self.children.get("page-1", []):
                if block.get("id") == block_id:
                    if "archived" in body:
                        return 400, {}, {"message": "archived was removed in API 2026-03-11"}
                    if body.get("in_trash"):
                        block["in_trash"] = True
                    else:
                        block_type = body.get("type") or next(iter(body), None)
                        if block_type in body:
                            block[block_type] = body[block_type]
                    return 200, {}, block
            raise AssertionError(f"unknown block: {block_id}")
        if method == "PATCH" and path.startswith("pages/"):
            page = self.pages[0]
            page["properties"].update(body["properties"])
            return 200, {}, page
        raise AssertionError(f"unexpected request: {method} {path}")


def write_archive(root: Path, *, turns: list[dict] | None = None) -> Path:
    archive = root / "archive"
    transcript_dir = archive / "transcripts" / "v1"
    transcript_dir.mkdir(parents=True)
    meeting_id = "11111111-1111-4111-8111-111111111111"
    metadata = {
        "schema_version": 1,
        "meeting_id": meeting_id,
        "manifest_revision": 1,
        "started_at": "2026-09-17T09:00:00+08:00",
        "ended_at": "2026-09-17T09:30:00+08:00",
        "duration_seconds": 1800,
        "timezone": "Australia/Perth",
        "source_app": "Google Meet",
        "title": "Planning",
        "description": "Discuss the launch plan.",
    }
    (archive / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
    (transcript_dir / "transcript.json").write_text(
        json.dumps({"meeting_id": meeting_id, "manifest_revision": 1, "turns": turns or [
            {"start": 1.5, "end": 3.0, "speaker": "Alice", "text": "Hello there."},
        ]}),
        encoding="utf-8",
    )
    return archive


def visible_text(value) -> str:
    if isinstance(value, dict):
        text = value.get("text")
        own = text.get("content", "") if isinstance(text, dict) else ""
        return own + "".join(visible_text(child) for child in value.values())
    if isinstance(value, list):
        return "".join(visible_text(child) for child in value)
    return ""


class NotionPublicationTests(unittest.TestCase):
    def test_publish_is_idempotent_and_preserves_manual_blocks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = write_archive(Path(temporary))
            transport = MockTransport()
            first = publish(archive, token="token", data_source="source", transport=transport)
            transport.children["page-1"].insert(0, {
                "id": "manual-1", "type": "paragraph", "paragraph": {
                    "rich_text": [{"type": "text", "text": {"content": "My notes"}}]
                }
            })
            (archive / "notion-receipt.json").unlink()
            second = publish(archive, token="token", data_source="source", transport=transport)

            self.assertEqual(first["page_id"], "page-1")
            self.assertEqual(second["page_id"], "page-1")
            self.assertEqual(len(transport.children["page-1"]), 5)
            self.assertEqual(transport.children["page-1"][0]["id"], "manual-1")
            self.assertTrue((archive / "notion-receipt.json").is_file())

    def test_ownership_uses_https_links_without_visible_internal_markers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = write_archive(Path(temporary))
            transport = MockTransport()
            publish(archive, token="token", data_source="source", transport=transport)
            properties = transport.pages[0]["properties"]
            for name in ("Audio file", "Transcript file"):
                items = properties[name]["rich_text"]
                self.assertEqual(len(items), 1)
                link = items[0]["text"]["link"]["url"]
                self.assertTrue(link.startswith(PLAYBACK_BASE + "/meeting/11111111-"))

            page_json = json.dumps(transport.pages[0])
            blocks_json = json.dumps(transport.children["page-1"])
            for internal_marker in ("<!-- meeting-archive:", "meetingarchive://"):
                self.assertNotIn(internal_marker, page_json)
                self.assertNotIn(internal_marker, blocks_json)
            self.assertNotIn("meeting-archive", visible_text({
                "page": transport.pages[0], "blocks": transport.children["page-1"],
            }))

            turn = next(block for block in transport.children["page-1"] if "Hello there." in json.dumps(block))
            rich_text = turn["paragraph"]["rich_text"]
            self.assertEqual(rich_text[0]["text"]["content"], "00:00:01")
            timestamp_link = rich_text[0]["text"]["link"]["url"]
            self.assertTrue(timestamp_link.startswith("https://"))
            self.assertIn("/meeting/11111111-1111-4111-8111-111111111111", timestamp_link)
            self.assertTrue(timestamp_link.endswith(
                "#t=1.5&meeting-archive=11111111-1111-4111-8111-111111111111:turn-0"
            ))

    def test_retry_migrates_old_receipt_markers_in_place(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = write_archive(Path(temporary))
            transport = MockTransport()
            first = publish(archive, token="token", data_source="source", transport=transport)
            receipt_path = archive / "notion-receipt.json"
            old_receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            old_receipt["marker"] = "meetingarchive://meeting/11111111-1111-4111-8111-111111111111"
            receipt_path.write_text(json.dumps(old_receipt), encoding="utf-8")

            old_prefix = "<!-- meeting-archive:11111111-1111-4111-8111-111111111111:"
            for key, block_id in first["owned_block_ids"].items():
                block = next(item for item in transport.children["page-1"] if item["id"] == block_id)
                block_type = block["type"]
                visible = "".join(item["text"]["content"] for item in block[block_type]["rich_text"])
                block[block_type]["rich_text"] = [{
                    "type": "text",
                    "text": {"content": f"{old_prefix}{key} -->\n{visible}"},
                }]
            transport.pages[0]["properties"]["Transcript file"]["rich_text"].append({
                "type": "text",
                "text": {"content": "meetingarchive://meeting/11111111-1111-4111-8111-111111111111"},
            })
            transport.children["page-1"].append({
                "id": "manual-1",
                "type": "paragraph",
                "paragraph": {"rich_text": [{"type": "text", "text": {"content": "Keep my notes"}}]},
            })

            second = publish(archive, token="token", data_source="source", transport=transport)

            self.assertEqual(second["owned_block_ids"], first["owned_block_ids"])
            self.assertEqual(second["marker"], PLAYBACK_BASE + "/meeting/11111111-1111-4111-8111-111111111111")
            self.assertEqual(len(transport.children["page-1"]), 5)
            self.assertEqual(transport.children["page-1"][-1]["id"], "manual-1")
            published = json.dumps({"page": transport.pages[0], "blocks": transport.children["page-1"]})
            self.assertNotIn("<!-- meeting-archive:", published)
            self.assertNotIn("meetingarchive://", published)

    def test_page_lookup_accepts_legacy_custom_scheme_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = write_archive(Path(temporary))
            transport = MockTransport()
            first = publish(archive, token="token", data_source="source", transport=transport)
            (archive / "notion-receipt.json").unlink()
            properties = transport.pages[0]["properties"]
            properties["Audio file"]["rich_text"] = [{
                "type": "text", "text": {"content": "Play recording"},
            }]
            properties["Transcript file"]["rich_text"] = [{
                "type": "text", "text": {"content": "Transcript"},
            }, {
                "type": "text",
                "text": {"content": "meetingarchive://meeting/11111111-1111-4111-8111-111111111111"},
            }]
            old_prefix = "<!-- meeting-archive:11111111-1111-4111-8111-111111111111:"
            for key, block_id in first["owned_block_ids"].items():
                block = next(item for item in transport.children["page-1"] if item["id"] == block_id)
                block_type = block["type"]
                content = visible_text(block[block_type]["rich_text"])
                block[block_type]["rich_text"] = [{
                    "type": "text", "text": {"content": f"{old_prefix}{key} -->\n{content}"},
                }]

            second = publish(archive, token="token", data_source="source", transport=transport)

            self.assertEqual(second["page_id"], first["page_id"])
            self.assertEqual(second["owned_block_ids"], first["owned_block_ids"])
            self.assertEqual(len(transport.pages), 1)
            self.assertNotIn("meetingarchive://", json.dumps(transport.pages[0]))

    def test_rejects_unusable_or_credential_bearing_playback_routes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = write_archive(Path(temporary))
            for url in ("", "meetingarchive://meeting", "http://bruce", "https://user:secret@bruce", "https://bruce/?token=secret", "https://bruce/#fragment"):
                with self.subTest(url=url):
                    transport = MockTransport()
                    with self.assertRaises(ValueError):
                        publish(archive, token="token", data_source="source", transport=transport, playback_base_url=url)
                    self.assertEqual(transport.calls, [])

    def test_changing_playback_route_refreshes_existing_page(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = write_archive(Path(temporary))
            transport = MockTransport()
            first = publish(archive, token="token", data_source="source", transport=transport)
            calls_before = len(transport.calls)
            second = publish(archive, token="token", data_source="source", transport=transport,
                             playback_base_url="https://new.example.ts.net")
            self.assertEqual(first["page_id"], second["page_id"])
            self.assertGreater(len(transport.calls), calls_before)
            self.assertNotEqual(first["content_fingerprint"], second["content_fingerprint"])

    def test_property_update_failure_does_not_acknowledge_publication(self) -> None:
        from meeting_archive_worker.notion import NotionError

        with tempfile.TemporaryDirectory() as temporary:
            archive = write_archive(Path(temporary))
            transport = MockTransport()

            def reject_property_update(request):
                if request.method == "PATCH" and "/v1/pages/" in request.full_url:
                    return 400, {}, {"message": "property shape is incompatible"}
                return transport(request)

            with self.assertRaises(NotionError):
                publish(archive, token="token", data_source="source", transport=reject_property_update)
            self.assertFalse((archive / "notion-receipt.json").exists())

    def test_long_transcript_chunks_rich_text_and_batches_at_100_blocks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            turns = [{"start": i, "end": i + 1, "speaker": "A", "text": "x" * 2500} for i in range(205)]
            archive = write_archive(Path(temporary), turns=turns)
            transport = MockTransport()
            publish(archive, token="token", data_source="source", transport=transport)

            appends = [body for method, path, body in transport.calls if method == "PATCH" and path.endswith("/children")]
            self.assertGreater(len(appends), 2)
            self.assertTrue(all(len(body["children"]) <= 100 for body in appends))
            for block in transport.children["page-1"]:
                for item in block.get(block.get("type", ""), {}).get("rich_text", []):
                    self.assertLessEqual(len(item["text"]["content"]), 2000)

    def test_uncertain_create_and_append_are_recovered_by_markers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = write_archive(Path(temporary))
            transport = MockTransport()
            transport.fail_create_once = True
            transport.fail_append_once = True
            first = publish(archive, token="token", data_source="source", transport=transport)
            second = publish(archive, token="token", data_source="source", transport=transport)
            self.assertEqual(first["page_id"], second["page_id"])
            self.assertEqual(len(transport.children["page-1"]), 4)

    def test_rate_limit_uses_retry_after_with_bounded_retry(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = write_archive(Path(temporary))
            transport = MockTransport()
            transport.rate_limit_once = True
            delays: list[float] = []
            publish(archive, token="token", data_source="source", transport=transport, sleep=delays.append)
            self.assertEqual(delays, [0.0])

    def test_correction_updates_owned_block_and_keeps_manual_and_unknown_blocks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = write_archive(Path(temporary))
            transport = MockTransport()
            first = publish(archive, token="token", data_source="source", transport=transport)
            transport.children["page-1"].append({"id": "manual-1", "type": "paragraph", "paragraph": {"rich_text": []}})
            transport.children["page-1"].append({"id": "unknown-1", "type": "unsupported", "unsupported": {"value": "keep"}})
            transcript_path = archive / "transcripts" / "v1" / "transcript.json"
            transcript = json.loads(transcript_path.read_text(encoding="utf-8"))
            transcript["turns"][0]["speaker"] = "Bob"
            transcript["turns"][0]["text"] = "Corrected words."
            transcript_path.write_text(json.dumps(transcript), encoding="utf-8")
            (archive / "notion-receipt.json").unlink()

            second = publish(archive, token="token", data_source="source", transport=transport)
            self.assertEqual(first["page_id"], second["page_id"])
            owned = [b for b in transport.children["page-1"] if b.get("id") in second["owned_block_ids"].values()]
            self.assertTrue(any("Corrected words." in text for block in owned for text in str(block).splitlines()))
            self.assertEqual(transport.children["page-1"][-1]["id"], "unknown-1")

            calls_before = len(transport.calls)
            third = publish(archive, token="token", data_source="source", transport=transport)
            self.assertEqual(second["content_fingerprint"], third["content_fingerprint"])
            self.assertEqual(len(transport.calls), calls_before)

    def test_correction_archives_removed_block_only_from_prior_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = write_archive(Path(temporary))
            transport = MockTransport()
            first = publish(archive, token="token", data_source="source", transport=transport)
            turn_id = first["owned_block_ids"]["turn-0"]
            transcript_path = archive / "transcripts" / "v1" / "transcript.json"
            transcript = json.loads(transcript_path.read_text(encoding="utf-8"))
            transcript["turns"] = []
            transcript_path.write_text(json.dumps(transcript), encoding="utf-8")

            second = publish(archive, token="token", data_source="source", transport=transport)
            removed = next(block for block in transport.children["page-1"] if block.get("id") == turn_id)
            self.assertTrue(removed.get("in_trash"))
            self.assertNotIn("turn-0", second["owned_block_ids"])

    def test_confirmed_display_name_is_used_in_page_and_transcript(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = write_archive(Path(temporary), turns=[{
                "start": 1.5,
                "end": 3.0,
                "speaker": "incoming:SPEAKER_00",
                "name": "Kelsie",
                "channel_origin": "incoming",
                "text": "Hello there.",
            }])
            transport = MockTransport()
            publish(archive, token="token", data_source="source", transport=transport)

            properties = transport.pages[0]["properties"]
            speaker_text = "".join(item["text"]["content"] for item in properties["Speakers"]["rich_text"])
            block_text = json.dumps(transport.children["page-1"])
            self.assertEqual(speaker_text, "Kelsie")
            self.assertIn("Kelsie: Hello there.", block_text)
            self.assertNotIn("incoming:SPEAKER_00: Hello there.", block_text)


class RealTransportLifecycleTests(unittest.TestCase):
    def test_response_is_consumed_before_context_closes(self):
        from unittest.mock import patch
        from urllib.request import Request
        from meeting_archive_worker.notion import _UrllibTransport

        class Response:
            status = 200
            headers = {"Content-Type": "application/json"}
            closed = False

            def __enter__(self): return self
            def __exit__(self, *_): self.closed = True
            def read(self):
                if self.closed: raise ValueError("response was closed")
                return b'{"id":"page-1"}'

        response = Response()
        with patch("meeting_archive_worker.notion.urlopen", return_value=response):
            result = _UrllibTransport()(Request("https://api.notion.com/v1/pages/page-1"))
        self.assertEqual(result[2], b'{"id":"page-1"}')
        self.assertTrue(response.closed)


if __name__ == "__main__":
    unittest.main()
