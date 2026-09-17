"""Bounded, additive publication of an archive into a Notion data source.

This module deliberately uses only the Python standard library.  The transport
is injected so a worker can be tested without credentials or a network.  Pages
and blocks are identified by markers owned by this publisher; other Notion
properties and blocks are left alone.
"""

from __future__ import annotations

import json
import hashlib
import os
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Protocol
from uuid import UUID
from urllib.error import HTTPError
from urllib.parse import parse_qsl, urlencode, urlsplit
from urllib.request import Request, urlopen


NOTION_VERSION = "2026-03-11"
NOTION_ENDPOINT = "https://api.notion.com/v1"
MAX_RICH_TEXT = 2_000
MAX_BLOCKS = 100
MAX_RETRIES = 3
RECEIPT_NAME = "notion-receipt.json"


class NotionTransport(Protocol):
    def __call__(self, request: Request) -> Any:
        """Return a response, or (status, headers, JSON-compatible body)."""


class NotionError(RuntimeError):
    """A bounded Notion request or archive publication failure."""


class _HTTPError(NotionError):
    def __init__(self, status: int, body: Any, headers: Any = None):
        self.status = status
        self.body = body
        self.headers = headers
        message = body.get("message") if isinstance(body, dict) else str(body)
        super().__init__(f"Notion request failed (HTTP {status}): {message}")


class _UrllibTransport:
    def __call__(self, request: Request) -> Any:
        with urlopen(request, timeout=30) as response:  # noqa: S310 - endpoint is fixed
            # Consume while the response is open. Returning it out of this
            # context closes the socket before the caller can read its JSON.
            return response.status, dict(response.headers), response.read()


def _header(headers: Any, name: str) -> str | None:
    if headers is None:
        return None
    if hasattr(headers, "get"):
        value = headers.get(name) or headers.get(name.lower())
        return str(value) if value is not None else None
    if isinstance(headers, dict):
        for key, value in headers.items():
            if str(key).lower() == name.lower():
                return str(value)
    return None


def _response_parts(value: Any) -> tuple[int, Any, bytes]:
    """Accept urllib responses and small tuple responses used by test doubles."""
    if isinstance(value, tuple):
        if len(value) == 3:
            status, headers, body = value
            if isinstance(body, bytes):
                raw = body
            else:
                raw = json.dumps(body).encode("utf-8")
            return int(status), headers, raw
        if len(value) == 2:
            first, second = value
            if hasattr(second, "status"):
                status, headers, body = _response_parts(second)
                return status, headers, first if isinstance(first, bytes) else json.dumps(first).encode()
    status = int(getattr(value, "status", getattr(value, "status_code", getattr(value, "code", 200))))
    headers = getattr(value, "headers", None)
    body = value.read() if hasattr(value, "read") else value
    if isinstance(body, str):
        body = body.encode("utf-8")
    if not isinstance(body, bytes):
        body = json.dumps(body).encode("utf-8")
    return status, headers, body


def _decode(body: bytes) -> Any:
    if not body:
        return {}
    try:
        return json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return body.decode("utf-8", errors="replace")


def _chunks(value: str) -> list[str]:
    value = str(value)
    return [value[index : index + MAX_RICH_TEXT] for index in range(0, len(value), MAX_RICH_TEXT)] or [""]


def _rich_text(value: str, *, link: str | None = None) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    pieces = _chunks(value)
    for piece in pieces:
        text: dict[str, Any] = {"content": piece}
        if link is not None:
            text["link"] = {"url": link}
        result.append({"type": "text", "text": text})
    return result


def _property_rich_text(value: str) -> dict[str, Any]:
    return {"type": "rich_text", "rich_text": _rich_text(value)}


def _linked_property(label: str, link: str) -> dict[str, Any]:
    return {"type": "rich_text", "rich_text": _rich_text(label, link=link)}


def _strings(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, dict):
        result: list[str] = []
        for child in value.values():
            result.extend(_strings(child))
        return result
    if isinstance(value, list):
        result = []
        for child in value:
            result.extend(_strings(child))
        return result
    return []


def _owned_marker(value: Any) -> str | None:
    for item in _strings(value):
        route = urlsplit(item)
        if route.scheme == "https":
            marker_value = next(
                (value for key, value in parse_qsl(route.fragment) if key == "meeting-archive"),
                None,
            )
            parts = marker_value.split(":", 1) if marker_value is not None else []
            if len(parts) != 2 or not parts[1]:
                continue
            try:
                meeting_id = str(UUID(parts[0]))
            except (ValueError, AttributeError):
                continue
            if parts[0].lower() != meeting_id or not route.path.rstrip("/").endswith(f"/meeting/{meeting_id}"):
                continue
            return f"meeting-archive:{meeting_id}:{parts[1]}"

        # Receipts from the first publisher version point at blocks whose
        # ownership marker was rendered as a visible HTML comment. Parse them
        # during migration, but never produce this format again.
        start = item.find("<!-- meeting-archive:")
        if start < 0:
            continue
        end = item.find("-->", start)
        if end >= 0:
            legacy = item[start + len("<!-- ") : end]
            parts = legacy.split(":", 2)
            if len(parts) != 3 or not parts[2]:
                continue
            try:
                meeting_id = str(UUID(parts[1]))
            except (ValueError, AttributeError):
                continue
            if parts[1].lower() == meeting_id:
                return f"meeting-archive:{meeting_id}:{parts[2].strip()}"
    return None


def _content_fingerprint(metadata: dict[str, Any], transcript: dict[str, Any], playback_base_url: str) -> str:
    encoded = json.dumps(
        {"metadata": metadata, "transcript": transcript, "playback_base_url": playback_base_url},
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _block(block_type: str, parts: list[tuple[str, str | None]]) -> dict[str, Any]:
    rich: list[dict[str, Any]] = []
    for content, link in parts:
        rich.extend(_rich_text(content, link=link))
    return {"object": "block", "type": block_type, block_type: {"rich_text": rich}}


def _timestamp(value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        raise NotionError("metadata.json started_at is required for Notion publication.")
    return value


def _description(metadata: dict[str, Any], transcript: dict[str, Any] | None = None) -> str:
    supplied = metadata.get("description")
    if isinstance(supplied, str) and supplied.strip():
        return supplied.strip()
    # Keep the fallback extractive and deterministic. It is useful for archives
    # created before a title/description review was added to the app.
    if transcript:
        for turn in transcript.get("turns", []):
            if isinstance(turn, dict) and isinstance(turn.get("text"), str) and turn["text"].strip():
                text = " ".join(turn["text"].split())
                return f"Discussion begins: {text[:240]}"
    return f"Recorded from {metadata.get('source_app', 'meeting capture')}."


def _archive_data(archive: Path) -> tuple[dict[str, Any], dict[str, Any], Path]:
    try:
        metadata = json.loads((archive / "metadata.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise NotionError(f"Could not read archive metadata: {error}") from error
    if not isinstance(metadata, dict):
        raise NotionError("metadata.json must contain an object.")
    meeting_id = metadata.get("meeting_id")
    revision = metadata.get("manifest_revision", 1)
    if not isinstance(meeting_id, str) or not meeting_id:
        raise NotionError("metadata.json meeting_id is required for Notion publication.")
    transcript_path = archive / "transcripts" / f"v{revision}" / "transcript.json"
    try:
        transcript = json.loads(transcript_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise NotionError(f"Could not read archive transcript: {error}") from error
    if not isinstance(transcript, dict) or not isinstance(transcript.get("turns", []), list):
        raise NotionError("transcript.json must contain a turns array.")
    return metadata, transcript, transcript_path


class NotionPublisher:
    def __init__(
        self,
        token: str,
        data_source: str,
        transport: NotionTransport | None = None,
        *,
        playback_base_url: str,
        sleep: Callable[[float], None] = time.sleep,
        max_retries: int = MAX_RETRIES,
    ) -> None:
        if not token.strip() or not data_source.strip():
            raise ValueError("Notion token and data source are required.")
        route = urlsplit(playback_base_url)
        if (route.scheme != "https" or not route.hostname or route.username is not None
                or route.password is not None or route.query or route.fragment
                or any(character.isspace() for character in playback_base_url)):
            raise ValueError("A credential-free private HTTPS playback base URL is required.")
        self.playback_base_url = playback_base_url.rstrip("/")
        self.token = token
        self.data_source = data_source
        self.transport = transport or _UrllibTransport()
        self.sleep = sleep
        self.max_retries = max(0, min(int(max_retries), MAX_RETRIES))

    def _request(self, method: str, path: str, body: dict[str, Any] | None = None) -> Any:
        query_path = path
        payload = json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Notion-Version": NOTION_VERSION,
            "Content-Type": "application/json",
        }
        for attempt in range(self.max_retries + 1):
            request = Request(NOTION_ENDPOINT + query_path, data=payload, headers=headers, method=method)
            try:
                response = self.transport(request)
                status, response_headers, raw = _response_parts(response)
            except HTTPError as error:
                status, response_headers, raw = error.code, error.headers, error.read()
            except Exception:
                raise
            parsed = _decode(raw)
            if status == 429 and attempt < self.max_retries:
                retry_after = _header(response_headers, "Retry-After")
                try:
                    delay = max(0.0, float(retry_after)) if retry_after is not None else 1.0 * (2**attempt)
                except ValueError:
                    delay = 1.0 * (2**attempt)
                self.sleep(min(delay, 30.0))
                continue
            if status < 200 or status >= 300:
                raise _HTTPError(status, parsed, response_headers)
            return parsed
        raise NotionError("Notion request retry budget was exhausted.")

    def _query_pages(self, meeting_id: str) -> list[dict[str, Any]]:
        cursor: str | None = None
        pages: list[dict[str, Any]] = []

        def is_owned(page: dict[str, Any]) -> bool:
            legacy = f"meetingarchive://meeting/{meeting_id}"
            for item in _strings(page):
                if item == legacy:
                    return True
                route = urlsplit(item)
                if route.scheme == "https" and route.path.rstrip("/").endswith(f"/meeting/{meeting_id}"):
                    return True
            return False

        while True:
            body: dict[str, Any] = {"page_size": 100}
            if cursor:
                body["start_cursor"] = cursor
            response = self._request("POST", f"/data_sources/{self.data_source}/query", body)
            pages.extend(item for item in response.get("results", []) if isinstance(item, dict))
            if not response.get("has_more"):
                return [page for page in pages if is_owned(page)]
            cursor = response.get("next_cursor")
            if not isinstance(cursor, str) or not cursor:
                return [page for page in pages if is_owned(page)]

    def _children(self, page_id: str) -> list[dict[str, Any]]:
        cursor: str | None = None
        blocks: list[dict[str, Any]] = []
        while True:
            suffix = f"?{urlencode({'page_size': 100, 'start_cursor': cursor})}" if cursor else "?page_size=100"
            response = self._request("GET", f"/blocks/{page_id}/children{suffix}")
            blocks.extend(item for item in response.get("results", []) if isinstance(item, dict))
            if not response.get("has_more"):
                return blocks
            cursor = response.get("next_cursor")
            if not isinstance(cursor, str) or not cursor:
                return blocks

    def _page_properties(
        self,
        metadata: dict[str, Any],
        meeting_id: str,
        transcript: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        title = str(metadata.get("title") or f"Meeting {meeting_id}")
        description = _description(metadata, transcript)
        speakers_list: list[str] = []
        if transcript:
            for turn in transcript.get("turns", []):
                if isinstance(turn, dict):
                    speaker = turn.get("name") or turn.get("speaker") or turn.get("channel_origin")
                    if isinstance(speaker, str) and speaker.strip() and speaker not in speakers_list:
                        speakers_list.append(speaker)
        speakers = metadata.get("speakers") if isinstance(metadata.get("speakers"), str) else ", ".join(speakers_list)
        playback_link = f"{self.playback_base_url}/meeting/{meeting_id}"
        return {
            "Name": {"type": "title", "title": _rich_text(title)},
            "Started": {
                "type": "date",
                "date": {"start": _timestamp(metadata.get("started_at")), "end": metadata.get("ended_at")},
            },
            "Duration": {"type": "number", "number": metadata.get("duration_seconds", 0)},
            "Speakers": _property_rich_text(speakers),
            "Description": _property_rich_text(description),
            "Audio file": _linked_property(
                "Play recording", playback_link + f"#meeting-archive={meeting_id}:audio"
            ),
            "Transcript file": _linked_property(
                "Transcript", playback_link + f"#meeting-archive={meeting_id}:transcript-file"
            ),
        }

    def _blocks(self, metadata: dict[str, Any], transcript: dict[str, Any], meeting_id: str) -> list[tuple[str, dict[str, Any]]]:
        playback_link = f"{self.playback_base_url}/meeting/{meeting_id}"

        def owned_link(key: str, seconds: float | None = None) -> str:
            seek = f"t={seconds:g}&" if seconds is not None else ""
            return playback_link + f"#{seek}meeting-archive={meeting_id}:{key}"

        title = str(metadata.get("title") or "Meeting Archive")
        description = _description(metadata, transcript)
        blocks: list[tuple[str, dict[str, Any]]] = [
            ("metadata", _block("heading_1", [
                (title + " · ", None),
                ("Play recording", owned_link("metadata")),
            ])),
            ("description", _block("paragraph", [(str(description), owned_link("description"))])),
            ("transcript", _block("heading_1", [("Transcript", owned_link("transcript"))])),
        ]
        for index, turn in enumerate(transcript.get("turns", [])):
            if not isinstance(turn, dict):
                continue
            text = str(turn.get("text", "")).strip()
            if not text:
                continue
            try:
                seconds = max(0.0, float(turn.get("start", 0)))
            except (TypeError, ValueError):
                seconds = 0.0
            total = int(seconds)
            timestamp = f"{total // 3600:02d}:{(total % 3600) // 60:02d}:{total % 60:02d}"
            speaker = str(
                turn.get("name")
                or turn.get("speaker")
                or turn.get("channel_origin")
                or "Unknown speaker"
            )
            key = f"turn-{index}"
            blocks.append((key, _block("paragraph", [
                (timestamp, owned_link(key, seconds)),
                (f"  {speaker}: {text}", None),
            ])))
        return blocks

    def _update_owned_block(self, block_id: str, block: dict[str, Any]) -> None:
        block_type = block.get("type")
        if not isinstance(block_type, str) or not isinstance(block.get(block_type), dict):
            raise NotionError("An owned block has an invalid Notion shape.")
        self._request("PATCH", f"/blocks/{block_id}", {block_type: block[block_type]})

    def _archive_owned_block(self, block_id: str) -> None:
        self._request("PATCH", f"/blocks/{block_id}", {"in_trash": True})

    def _reconcile_owned_blocks(
        self,
        page_id: str,
        blocks: list[tuple[str, dict[str, Any]]],
        previous_ids: dict[str, str] | None = None,
    ) -> dict[str, str]:
        """Update, append, or archive only blocks owned by an earlier receipt."""
        existing = self._children(page_id)
        by_id = {block["id"]: block for block in existing if isinstance(block.get("id"), str)}
        by_marker = {
            marker: block
            for block in existing
            if (marker := _owned_marker(block)) is not None and isinstance(block.get("id"), str)
        }
        previous_ids = previous_ids or {}
        found: dict[str, str] = {}
        pending: list[tuple[str, dict[str, Any]]] = []
        desired_keys = {key for key, _ in blocks}
        for key, candidate in blocks:
            marker = _owned_marker(candidate)
            current = by_id.get(previous_ids.get(key, ""))
            if current is None and marker:
                current = by_marker.get(marker)
            if current is None or not isinstance(current.get("id"), str):
                pending.append((key, candidate))
                continue
            block_id = current["id"]
            found[key] = block_id
            block_type = candidate.get("type")
            if current.get("type") != block_type or current.get(block_type) != candidate.get(block_type):
                self._update_owned_block(block_id, candidate)

        # A transcript correction can remove turns. Receipt IDs make this safe:
        # a page's manual or unknown blocks are never eligible for archiving.
        desired_ids = set(found.values())
        for key, block_id in previous_ids.items():
            if key not in desired_keys and block_id not in desired_ids and block_id in by_id:
                self._archive_owned_block(block_id)

        for offset in range(0, len(pending), MAX_BLOCKS):
            batch = pending[offset : offset + MAX_BLOCKS]
            try:
                response = self._request("PATCH", f"/blocks/{page_id}/children", {"children": [block for _, block in batch]})
            except Exception:
                # PATCH may have committed before its response was lost.
                discovered = self._children(page_id)
                for key, candidate in batch:
                    marker = _owned_marker(candidate)
                    for block in discovered:
                        if marker and _owned_marker(block) == marker and isinstance(block.get("id"), str):
                            found[key] = block["id"]
                            break
                if any(key not in found for key, _ in batch):
                    raise
                continue
            returned = response.get("results", []) if isinstance(response, dict) else []
            if isinstance(returned, list):
                for (key, _), created in zip(batch, returned):
                    if isinstance(created, dict) and isinstance(created.get("id"), str):
                        found[key] = created["id"]
            if len(returned) < len(batch):
                for block in self._children(page_id):
                    for key, candidate in batch:
                        marker = _owned_marker(candidate)
                        if key not in found and marker and _owned_marker(block) == marker:
                            if isinstance(block.get("id"), str):
                                found[key] = block["id"]
        if any(key not in found for key, _ in blocks):
            raise NotionError("Notion did not confirm all owned transcript blocks.")
        return found

    def publish(self, archive_directory: Path | str) -> dict[str, Any]:
        archive = Path(archive_directory)
        metadata, transcript, _ = _archive_data(archive)
        meeting_id = str(metadata["meeting_id"])
        marker = f"{self.playback_base_url}/meeting/{meeting_id}"
        receipt_path = archive / RECEIPT_NAME
        fingerprint = _content_fingerprint(metadata, transcript, self.playback_base_url)
        if receipt_path.is_file():
            try:
                receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
                if (
                    receipt.get("meeting_id") == meeting_id
                    and receipt.get("data_source") == self.data_source
                    and receipt.get("content_fingerprint") == fingerprint
                    and receipt.get("marker") == marker
                ):
                    return receipt
            except (OSError, json.JSONDecodeError):
                pass

        old_receipt: dict[str, Any] | None = None
        if receipt_path.is_file():
            try:
                candidate_receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
                if candidate_receipt.get("meeting_id") == meeting_id and candidate_receipt.get("data_source") == self.data_source:
                    old_receipt = candidate_receipt
            except (OSError, json.JSONDecodeError):
                pass
        pages = [] if old_receipt and isinstance(old_receipt.get("page_id"), str) else self._query_pages(meeting_id)
        page = pages[0] if pages else None
        if page is None and old_receipt and isinstance(old_receipt.get("page_id"), str):
            page = {"id": old_receipt["page_id"], "url": old_receipt.get("page_url"), "properties": {}}
        if page is None:
            properties = self._page_properties(metadata, meeting_id, transcript)
            body = {"parent": {"type": "data_source_id", "data_source_id": self.data_source}, "properties": properties}
            try:
                page = self._request("POST", "/pages", body)
            except Exception:
                # POST /pages is uncertain: the server may have committed it
                # before the client lost the response. Marker lookup is bounded.
                recovered = self._query_pages(meeting_id)
                if not recovered:
                    raise
                page = recovered[0]
        page_id = page.get("id") if isinstance(page, dict) else None
        if not isinstance(page_id, str) or not page_id:
            raise NotionError("Notion did not return a page ID.")

        # Update only the known fields. Existing unknown/manual properties stay intact.
        existing_properties = page.get("properties", {}) if isinstance(page, dict) else {}
        properties = self._page_properties(metadata, meeting_id, transcript)
        if isinstance(existing_properties, dict) and "Meeting ID" in existing_properties:
            properties["Meeting ID"] = _property_rich_text(meeting_id)
        # A rejected property update must remain retryable. A receipt here would
        # incorrectly mark a stale title, speaker list, or link as published.
        self._request("PATCH", f"/pages/{page_id}", {"properties": properties})

        owned = self._reconcile_owned_blocks(
            page_id,
            self._blocks(metadata, transcript, meeting_id),
            old_receipt.get("owned_block_ids", {}) if old_receipt else {},
        )
        receipt: dict[str, Any] = {
            "schema_version": 1,
            "meeting_id": meeting_id,
            "manifest_revision": metadata.get("manifest_revision", 1),
            "data_source": self.data_source,
            "page_id": page_id,
            "page_url": page.get("url") if isinstance(page, dict) else None,
            "marker": marker,
            "owned_block_ids": owned,
            "content_revision": metadata.get("manifest_revision", 1),
            "content_fingerprint": fingerprint,
            "published_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        }
        self._write_receipt(receipt_path, receipt)
        return receipt

    @staticmethod
    def _write_receipt(path: Path, receipt: dict[str, Any]) -> None:
        encoded = (json.dumps(receipt, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")
        descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(encoded)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary_name, path)
            try:
                directory = os.open(path.parent, os.O_RDONLY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
            except OSError:
                pass
        finally:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass


def publish(
    archive_directory: Path | str,
    *,
    token: str | None = None,
    data_source: str | None = None,
    playback_base_url: str | None = None,
    transport: NotionTransport | None = None,
    sleep: Callable[[float], None] = time.sleep,
    max_retries: int = MAX_RETRIES,
) -> dict[str, Any]:
    """Publish one finalized archive using explicit values or environment credentials."""
    resolved_token = token or os.environ.get("MEETING_ARCHIVE_NOTION_TOKEN", "")
    resolved_source = data_source or os.environ.get("MEETING_ARCHIVE_NOTION_DATA_SOURCE", "")
    resolved_playback = playback_base_url if playback_base_url is not None else os.environ.get("MEETING_ARCHIVE_PLAYBACK_BASE_URL", "")
    return NotionPublisher(
        resolved_token,
        resolved_source,
        transport=transport,
        playback_base_url=resolved_playback,
        sleep=sleep,
        max_retries=max_retries,
    ).publish(archive_directory)


__all__ = ["NotionError", "NotionPublisher", "NotionTransport", "publish"]
