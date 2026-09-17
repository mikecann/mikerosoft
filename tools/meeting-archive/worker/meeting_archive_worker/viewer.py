"""Private, read-only playback viewer intended only behind Tailscale Serve."""

from __future__ import annotations

import argparse
import html
import json
import math
import os
import re
import secrets
import socketserver
import sqlite3
import stat
import uuid
from dataclasses import dataclass
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from threading import BoundedSemaphore
from urllib.parse import urlsplit
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765
DEFAULT_ALLOWED_LOGIN = "mike.cann@gmail.com"
MAX_METADATA_BYTES = 1024 * 1024
MAX_TRANSCRIPT_BYTES = 8 * 1024 * 1024
MAX_TRANSCRIPT_TURNS = 20_000
STREAM_CHUNK_BYTES = 64 * 1024
MAX_RANGE_HEADER_BYTES = 128

_UUID = r"(?P<meeting_id>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"
_LANDING_ROUTE = re.compile(rf"^/meeting/{_UUID}$")
_PLAYBACK_ROUTE = re.compile(rf"^/meeting/{_UUID}/playback\.mp4$")
_TRANSCRIPT_ROUTE = re.compile(rf"^/meeting/{_UUID}/transcript\.md$")
_RANGE = re.compile(r"^bytes=([0-9]*)-([0-9]*)$")

_DIRECTORY_FLAGS = (
    os.O_RDONLY
    | getattr(os, "O_DIRECTORY", 0)
    | getattr(os, "O_NOFOLLOW", 0)
    | getattr(os, "O_CLOEXEC", 0)
)
_FILE_FLAGS = (
    os.O_RDONLY
    | getattr(os, "O_NOFOLLOW", 0)
    | getattr(os, "O_CLOEXEC", 0)
)


class ViewerNotFound(Exception):
    pass


class ViewerUnavailable(Exception):
    pass


class ViewerTooLarge(Exception):
    pass


class InvalidRange(Exception):
    pass


@dataclass(frozen=True)
class Acceptance:
    meeting_id: str
    revision: int
    archive_parts: tuple[str, str, str]


@dataclass(frozen=True)
class ViewerState:
    archive_root: Path
    archive_root_lexical: Path
    database: Path
    allowed_login: str

    def acceptance(self, meeting_id: str) -> Acceptance:
        try:
            database_stat = self.database.lstat()
        except FileNotFoundError as error:
            raise ViewerUnavailable from error
        if stat.S_ISLNK(database_stat.st_mode) or not stat.S_ISREG(database_stat.st_mode):
            raise ViewerUnavailable

        try:
            connection = sqlite3.connect(
                self.database.resolve(strict=True).as_uri() + "?mode=ro",
                uri=True,
                timeout=5,
            )
            connection.execute("PRAGMA query_only = ON")
            row = connection.execute(
                "SELECT manifest_revision, manifest_sha256, archive_path, "
                "acknowledgement_json FROM acceptances WHERE meeting_id = ?",
                (meeting_id,),
            ).fetchone()
        except (OSError, sqlite3.Error) as error:
            raise ViewerUnavailable from error
        finally:
            if "connection" in locals():
                connection.close()
        if row is None:
            raise ViewerNotFound

        revision, manifest_sha256, raw_archive_path, raw_acknowledgement = row
        try:
            acknowledgement = json.loads(raw_acknowledgement)
        except (TypeError, json.JSONDecodeError) as error:
            raise ViewerNotFound from error
        if (
            not isinstance(revision, int)
            or revision < 1
            or not isinstance(manifest_sha256, str)
            or len(manifest_sha256) != 64
            or not isinstance(raw_archive_path, str)
            or not isinstance(raw_acknowledgement, (str, bytes, bytearray))
            or not isinstance(acknowledgement, dict)
            or acknowledgement.get("schema_version") != 1
            or acknowledgement.get("meeting_id") != meeting_id
            or acknowledgement.get("manifest_revision") != revision
            or acknowledgement.get("manifest_sha256") != manifest_sha256
            or acknowledgement.get("archive_path") != raw_archive_path
        ):
            raise ViewerNotFound

        archive_path = Path(raw_archive_path)
        if not archive_path.is_absolute():
            raise ViewerNotFound
        relative = None
        # Compare the raw accepted path lexically. Resolving it here would erase
        # a symlink in year/month/meeting before openat gets a chance to reject
        # that component with O_NOFOLLOW. The canonical prefix also accepts a
        # database written through macOS's /var -> /private/var root alias.
        for prefix in (self.archive_root_lexical, self.archive_root):
            try:
                relative = archive_path.relative_to(prefix)
                break
            except ValueError:
                continue
        if relative is None:
            raise ViewerNotFound
        parts = relative.parts
        if (
            len(parts) != 3
            or any(part in ("", ".", "..") for part in parts)
            or not re.fullmatch(r"[0-9]{4}", parts[0])
            or not re.fullmatch(r"(?:0[1-9]|1[0-2])", parts[1])
            or parts[2] != meeting_id
        ):
            raise ViewerNotFound
        return Acceptance(meeting_id, revision, (parts[0], parts[1], parts[2]))

    def open_generated(self, acceptance: Acceptance, relative_parts: tuple[str, ...]):
        """Open a fixed generated file without following any archive symlinks."""

        try:
            directory = os.open(self.archive_root, _DIRECTORY_FLAGS)
        except OSError as error:
            raise ViewerNotFound from error
        try:
            for component in (*acceptance.archive_parts, *relative_parts[:-1]):
                if not component or component in (".", "..") or "/" in component:
                    raise ViewerNotFound
                try:
                    child = os.open(component, _DIRECTORY_FLAGS, dir_fd=directory)
                except OSError as error:
                    raise ViewerNotFound from error
                os.close(directory)
                directory = child
            try:
                descriptor = os.open(relative_parts[-1], _FILE_FLAGS, dir_fd=directory)
            except OSError as error:
                raise ViewerNotFound from error
            try:
                file_stat = os.fstat(descriptor)
                if not stat.S_ISREG(file_stat.st_mode):
                    raise ViewerNotFound
                return descriptor, file_stat
            except BaseException:
                os.close(descriptor)
                raise
        finally:
            os.close(directory)


class BoundedThreadingHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True
    block_on_close = True
    request_queue_size = 8
    request_timeout_seconds = 15

    def __init__(self, server_address, handler_class, *, state: ViewerState, max_threads: int):
        if not 1 <= max_threads <= 8:
            raise ValueError("max_threads must be between 1 and 8.")
        self.state = state
        self.max_threads = max_threads
        self._thread_slots = BoundedSemaphore(max_threads)
        super().__init__(server_address, handler_class)

    def get_request(self):
        request, client_address = super().get_request()
        request.settimeout(self.request_timeout_seconds)
        return request, client_address

    def process_request(self, request, client_address) -> None:
        self._thread_slots.acquire()
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._thread_slots.release()
            raise

    def process_request_thread(self, request, client_address) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._thread_slots.release()


class ViewerRequestHandler(BaseHTTPRequestHandler):
    server_version = "MeetingArchiveViewer"
    sys_version = ""

    def __getattr__(self, name: str):
        # BaseHTTPRequestHandler otherwise emits its own unauthenticated HTML
        # 501 response for every unrecognized method token.
        if name.startswith("do_"):
            return self._method_not_allowed
        raise AttributeError(name)

    def do_GET(self) -> None:
        self._handle(send_body=True)

    def do_HEAD(self) -> None:
        self._handle(send_body=False)

    def do_POST(self) -> None:
        self._method_not_allowed()

    def do_PUT(self) -> None:
        self._method_not_allowed()

    def do_PATCH(self) -> None:
        self._method_not_allowed()

    def do_DELETE(self) -> None:
        self._method_not_allowed()

    def do_OPTIONS(self) -> None:
        self._method_not_allowed()

    def do_TRACE(self) -> None:
        self._method_not_allowed()

    def do_CONNECT(self) -> None:
        self._method_not_allowed()

    def log_message(self, _format: str, *_arguments) -> None:
        # Meeting titles and UUIDs are private. The service wrapper deliberately
        # emits no per-request path log.
        return

    @property
    def viewer(self) -> ViewerState:
        return self.server.state  # type: ignore[attr-defined]

    def _handle(self, *, send_body: bool) -> None:
        if not self._require_identity():
            return

        parsed = urlsplit(self.path)
        if parsed.query or parsed.fragment:
            self._empty_response(404)
            return
        route = parsed.path
        landing = _LANDING_ROUTE.fullmatch(route)
        playback = _PLAYBACK_ROUTE.fullmatch(route)
        transcript = _TRANSCRIPT_ROUTE.fullmatch(route)
        match = landing or playback or transcript
        if match is None:
            self._empty_response(404)
            return
        meeting_id = match.group("meeting_id")
        try:
            if str(uuid.UUID(meeting_id)) != meeting_id:
                raise ViewerNotFound
            acceptance = self.viewer.acceptance(meeting_id)
            if playback is not None:
                self._serve_generated(
                    acceptance,
                    ("playback", "meeting.mp4"),
                    content_type="video/mp4",
                    send_body=send_body,
                    allow_range=True,
                )
            elif transcript is not None:
                self._serve_generated(
                    acceptance,
                    ("transcripts", f"v{acceptance.revision}", "transcript.md"),
                    content_type="text/markdown; charset=utf-8",
                    send_body=send_body,
                    allow_range=False,
                )
            else:
                body, nonce = self._landing_page(acceptance)
                self._bytes_response(
                    200,
                    body,
                    content_type="text/html; charset=utf-8",
                    send_body=send_body,
                    nonce=nonce,
                )
        except ViewerTooLarge:
            self._empty_response(413)
        except ViewerUnavailable:
            self._empty_response(503)
        except ViewerNotFound:
            self._empty_response(404)
        except InvalidRange as error:
            self._empty_response(416, content_range=str(error))

    def _require_identity(self) -> bool:
        identities = self.headers.get_all("Tailscale-User-Login", failobj=[])
        if not identities:
            self._empty_response(401)
            return False
        if len(identities) != 1 or identities[0].strip() != self.viewer.allowed_login:
            self._empty_response(403)
            return False
        return True

    def _method_not_allowed(self) -> None:
        if not self._require_identity():
            return
        self._empty_response(405, allow="GET, HEAD")

    def _landing_page(self, acceptance: Acceptance) -> tuple[bytes, str]:
        metadata = _read_json(
            self.viewer.open_generated(acceptance, ("metadata.json",)),
            MAX_METADATA_BYTES,
        )
        transcript = _read_json(
            self.viewer.open_generated(
                acceptance,
                ("transcripts", f"v{acceptance.revision}", "transcript.json"),
            ),
            MAX_TRANSCRIPT_BYTES,
        )
        if (
            not isinstance(metadata, dict)
            or not isinstance(transcript, dict)
            or metadata.get("schema_version") != 1
            or metadata.get("meeting_id") != acceptance.meeting_id
            or metadata.get("manifest_revision") != acceptance.revision
            or transcript.get("meeting_id") != acceptance.meeting_id
            or transcript.get("manifest_revision") != acceptance.revision
            or not isinstance(transcript.get("turns"), list)
            or len(transcript["turns"]) > MAX_TRANSCRIPT_TURNS
        ):
            raise ViewerNotFound

        title = _escaped_text(metadata.get("title") or metadata.get("subject") or "Meeting")
        started_at = _escaped_text(_human_date(metadata))
        duration = _escaped_text(_human_duration(metadata.get("duration_seconds")))
        turns: list[str] = []
        unknown_speakers: dict[tuple[str, str], int] = {}
        for turn in transcript["turns"]:
            if not isinstance(turn, dict):
                raise ViewerNotFound
            start = turn.get("start")
            end = turn.get("end")
            if (
                not isinstance(start, (int, float))
                or isinstance(start, bool)
                or not isinstance(end, (int, float))
                or isinstance(end, bool)
                or not math.isfinite(start)
                or not math.isfinite(end)
                or start < 0
                or end < start
            ):
                raise ViewerNotFound
            label = _escaped_text(_speaker_label(turn, unknown_speakers))
            text = _escaped_text(turn.get("text") or "")
            turns.append(
                f'<li><a class="timestamp" href="#t={float(start):.3f}">{_timestamp(float(start))}</a> '
                f"<strong>{label}</strong> <span>{text}</span></li>"
            )

        nonce = secrets.token_urlsafe(18)
        meeting_id = acceptance.meeting_id
        playback_path = f"/meeting/{meeting_id}/playback.mp4"
        app_path = f"meetingarchive://meeting/{meeting_id}"
        script = (
            "const player=document.getElementById('playback');"
            "const seekFromHash=()=>{"
            "const value=new URLSearchParams(location.hash.slice(1)).get('t');"
            "if(value===null)return;const seconds=Number(value);"
            "if(!Number.isFinite(seconds)||seconds<0)return;"
            "const seek=()=>{player.currentTime=seconds;player.play().catch(()=>{});};"
            "if(player.readyState>0)seek();else player.addEventListener('loadedmetadata',seek,{once:true});"
            "};window.addEventListener('hashchange',seekFromHash);"
            "for(const link of document.querySelectorAll('.timestamp')){"
            "link.addEventListener('click',(event)=>{if(link.hash===location.hash){"
            "event.preventDefault();seekFromHash();}});"
            "}seekFromHash();"
        )
        style = (
            "body{font:16px system-ui,sans-serif;line-height:1.5;margin:0;color:#171717;background:#f6f6f4}"
            "main{max-width:900px;margin:0 auto;padding:32px 20px 64px}"
            "h1{line-height:1.15;margin-bottom:8px}video{display:block;width:100%;max-height:70vh;background:#000;margin:24px 0}"
            "ol{padding-left:0;list-style:none}li{padding:12px 0;border-bottom:1px solid #ddd}"
            ".timestamp{display:inline-block;min-width:4.5rem;font-variant-numeric:tabular-nums}"
        )
        document = (
            "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            f"<title>{title}</title><style nonce=\"{nonce}\">{style}</style></head>"
            f"<body><main><h1>{title}</h1><p>{started_at} · {duration}</p>"
            f'<p><a href="{app_path}">Open in Meeting Archive</a></p>'
            f'<video id="playback" controls preload="metadata" src="{playback_path}"></video>'
            f'<section id="transcript"><h2>Transcript</h2><ol>{"".join(turns)}</ol></section>'
            f'<script nonce="{nonce}">{script}</script></main></body></html>'
        )
        return document.encode("utf-8"), nonce

    def _serve_generated(
        self,
        acceptance: Acceptance,
        relative_parts: tuple[str, ...],
        *,
        content_type: str,
        send_body: bool,
        allow_range: bool,
    ) -> None:
        descriptor, file_stat = self.viewer.open_generated(acceptance, relative_parts)
        try:
            size = file_stat.st_size
            start = 0
            end = size - 1
            status = 200
            range_header = self.headers.get("Range") if allow_range else None
            range_headers = self.headers.get_all("Range", failobj=[]) if allow_range else []
            if len(range_headers) > 1:
                raise InvalidRange(f"bytes */{size}")
            if range_header is not None:
                try:
                    start, end = _parse_range(range_header, size)
                except InvalidRange:
                    raise InvalidRange(f"bytes */{size}")
                status = 206
            length = 0 if size == 0 else end - start + 1
            self.send_response(status)
            self._security_headers()
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(length))
            self.send_header("Accept-Ranges", "bytes" if allow_range else "none")
            if status == 206:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            if not send_body or length == 0:
                return
            os.lseek(descriptor, start, os.SEEK_SET)
            remaining = length
            try:
                while remaining:
                    chunk = os.read(descriptor, min(STREAM_CHUNK_BYTES, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
            except (BrokenPipeError, ConnectionResetError):
                return
        finally:
            os.close(descriptor)

    def _bytes_response(
        self,
        status: int,
        body: bytes,
        *,
        content_type: str,
        send_body: bool,
        nonce: str | None = None,
    ) -> None:
        self.send_response(status)
        self._security_headers(nonce=nonce)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if send_body:
            self.wfile.write(body)

    def _empty_response(
        self,
        status: int,
        *,
        content_range: str | None = None,
        allow: str | None = None,
    ) -> None:
        self.send_response(status)
        self._security_headers()
        self.send_header("Content-Length", "0")
        if content_range is not None:
            self.send_header("Content-Range", content_range)
        if allow is not None:
            self.send_header("Allow", allow)
        self.end_headers()

    def _security_headers(self, *, nonce: str | None = None) -> None:
        script_source = f"'nonce-{nonce}'" if nonce is not None else "'none'"
        self.send_header("Cache-Control", "private, no-store")
        self.send_header("Content-Security-Policy", f"default-src 'none'; media-src 'self'; style-src {script_source}; script-src {script_source}; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")


def _read_json(opened_file, maximum_bytes: int):
    descriptor, file_stat = opened_file
    try:
        if file_stat.st_size > maximum_bytes:
            raise ViewerTooLarge
        chunks: list[bytes] = []
        remaining = maximum_bytes + 1
        while remaining:
            chunk = os.read(descriptor, min(STREAM_CHUNK_BYTES, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
        if len(raw) > maximum_bytes:
            raise ViewerTooLarge
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ViewerNotFound from error
    finally:
        os.close(descriptor)


def _escaped_text(value) -> str:
    return html.escape(str(value), quote=True)


def _speaker_label(
    turn: dict,
    unknown_speakers: dict[tuple[str, str], int],
) -> str:
    name = turn.get("name")
    if isinstance(name, str) and name.strip():
        return name.strip()

    origin_value = turn.get("channel_origin")
    speaker_value = turn.get("speaker")
    origin = origin_value.strip() if isinstance(origin_value, str) else ""
    speaker = speaker_value.strip() if isinstance(speaker_value, str) else ""
    key = (origin, speaker)
    number = unknown_speakers.setdefault(key, len(unknown_speakers) + 1)
    label = f"Unknown speaker {number}"
    return f"{label} ({origin})" if origin else label


def _timestamp(seconds: float) -> str:
    total = max(0, int(seconds))
    hours, remainder = divmod(total, 3600)
    minutes, seconds_part = divmod(remainder, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds_part:02d}"


def _human_date(metadata: dict) -> str:
    raw = metadata.get("started_at")
    timezone_name = metadata.get("timezone")
    if not isinstance(raw, str) or not isinstance(timezone_name, str):
        raise ViewerNotFound
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError
        local = parsed.astimezone(ZoneInfo(timezone_name))
    except (ValueError, ZoneInfoNotFoundError) as error:
        raise ViewerNotFound from error
    return f"{local.day} {local.strftime('%b %Y, %H:%M %Z')}"


def _human_duration(value) -> str:
    if (
        not isinstance(value, (int, float))
        or isinstance(value, bool)
        or not math.isfinite(value)
        or value < 0
    ):
        raise ViewerNotFound
    total = int(round(value))
    hours, remainder = divmod(total, 3600)
    minutes, seconds_part = divmod(remainder, 60)
    parts: list[str] = []
    if hours:
        parts.append(f"{hours} hour{'s' if hours != 1 else ''}")
    if minutes:
        parts.append(f"{minutes} minute{'s' if minutes != 1 else ''}")
    if seconds_part or not parts:
        parts.append(f"{seconds_part} second{'s' if seconds_part != 1 else ''}")
    return " ".join(parts)


def _parse_range(value: str, size: int) -> tuple[int, int]:
    if len(value.encode("utf-8")) > MAX_RANGE_HEADER_BYTES or "," in value or size <= 0:
        raise InvalidRange
    match = _RANGE.fullmatch(value)
    if match is None:
        raise InvalidRange
    raw_start, raw_end = match.groups()
    if not raw_start and not raw_end:
        raise InvalidRange
    if not raw_start:
        suffix = int(raw_end)
        if suffix <= 0:
            raise InvalidRange
        start = max(0, size - suffix)
        return start, size - 1
    start = int(raw_start)
    if start >= size:
        raise InvalidRange
    end = size - 1 if not raw_end else int(raw_end)
    if end < start:
        raise InvalidRange
    return start, min(end, size - 1)


def _secure_regular_file(path: Path, description: str) -> Path:
    try:
        entry_stat = path.lstat()
    except FileNotFoundError as error:
        raise ValueError(f"{description} does not exist.") from error
    if stat.S_ISLNK(entry_stat.st_mode) or not stat.S_ISREG(entry_stat.st_mode):
        raise ValueError(f"{description} must be a real regular file.")
    return path.absolute()


def _secure_archive_root(path: Path) -> Path:
    try:
        entry_stat = path.lstat()
    except FileNotFoundError as error:
        raise ValueError("The meetings archive root does not exist.") from error
    if stat.S_ISLNK(entry_stat.st_mode) or not stat.S_ISDIR(entry_stat.st_mode):
        raise ValueError("The meetings archive root must be a real directory.")
    return path.resolve(strict=True)


def create_server(
    *,
    archive_root: Path | str,
    database: Path | str,
    host: str = DEFAULT_HOST,
    port: int = DEFAULT_PORT,
    allowed_login: str = DEFAULT_ALLOWED_LOGIN,
    max_threads: int = 4,
) -> BoundedThreadingHTTPServer:
    if host != DEFAULT_HOST:
        raise ValueError("The viewer may bind only to 127.0.0.1.")
    if not 0 <= int(port) <= 65535:
        raise ValueError("port must be between 0 and 65535.")
    if not allowed_login.strip() or "\r" in allowed_login or "\n" in allowed_login:
        raise ValueError("allowed_login must be a nonempty single-line identity.")
    lexical_archive_root = Path(archive_root).absolute()
    state = ViewerState(
        archive_root=_secure_archive_root(lexical_archive_root),
        archive_root_lexical=lexical_archive_root,
        database=_secure_regular_file(Path(database), "The worker database"),
        allowed_login=allowed_login.strip(),
    )
    return BoundedThreadingHTTPServer(
        (host, int(port)),
        ViewerRequestHandler,
        state=state,
        max_threads=int(max_threads),
    )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Serve accepted meeting playback on localhost.")
    result.add_argument("--archive-root", type=Path, required=True)
    result.add_argument("--db", type=Path, required=True)
    result.add_argument("--host", choices=(DEFAULT_HOST,), default=DEFAULT_HOST)
    result.add_argument("--port", type=int, default=DEFAULT_PORT)
    result.add_argument("--allowed-login", default=DEFAULT_ALLOWED_LOGIN)
    result.add_argument("--max-threads", type=int, default=4)
    return result


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    server = create_server(
        archive_root=arguments.archive_root,
        database=arguments.db,
        host=arguments.host,
        port=arguments.port,
        allowed_login=arguments.allowed_login,
        max_threads=arguments.max_threads,
    )
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
