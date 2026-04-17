"""Unix-socket control channel for the macOS menu bar helper."""

from __future__ import annotations

import json
import os
import socket
import threading
from typing import Any, Callable


JsonDict = dict[str, Any]


def apply_request(
    *,
    request: JsonDict,
    get_state: Callable[[], JsonDict],
    commands: dict[str, Callable[[JsonDict], Any]],
) -> JsonDict:
    if not isinstance(request, dict):
        return {"ok": False, "error": "invalid-request"}

    command = request.get("command")
    if command == "get_state":
        return {"ok": True, "state": get_state()}
    if not isinstance(command, str):
        return {"ok": False, "error": "missing-command", "state": get_state()}

    handler = commands.get(command)
    if handler is None:
        return {"ok": False, "error": f"unknown-command:{command}", "state": get_state()}

    try:
        result = handler(request)
    except Exception as exc:
        return {"ok": False, "error": str(exc), "state": get_state()}

    response = {"ok": True, "state": get_state()}
    if result is not None:
        response["result"] = result
    return response


def send_request(socket_path: str, request: JsonDict, timeout_sec: float = 1.5) -> JsonDict:
    payload = json.dumps(request).encode("utf-8")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(timeout_sec)
        client.connect(socket_path)
        client.sendall(payload)
        client.shutdown(socket.SHUT_WR)
        chunks: list[bytes] = []
        while True:
            chunk = client.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)

    if not chunks:
        raise RuntimeError("No response received from voice-type control server")
    return json.loads(b"".join(chunks).decode("utf-8"))


class ControlServer:
    def __init__(
        self,
        *,
        socket_path: str,
        get_state: Callable[[], JsonDict],
        commands: dict[str, Callable[[JsonDict], Any]],
        log: Callable[[str], None],
    ):
        self._socket_path = socket_path
        self._get_state = get_state
        self._commands = commands
        self._log = log
        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None
        self._server: socket.socket | None = None

    def start(self) -> None:
        if self._thread is not None:
            return
        self._remove_stale_socket()
        self._thread = threading.Thread(target=self._serve, daemon=True, name="voice-type-control")
        self._thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        if self._server is not None:
            try:
                self._server.close()
            except OSError:
                pass
            self._server = None
        self._remove_stale_socket()

    def _remove_stale_socket(self) -> None:
        if os.path.exists(self._socket_path):
            try:
                os.remove(self._socket_path)
            except OSError:
                pass

    def _serve(self) -> None:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            self._server = server
            server.bind(self._socket_path)
            server.listen()
            while not self._stop_event.is_set():
                try:
                    conn, _ = server.accept()
                except OSError:
                    break
                with conn:
                    request = self._read_request(conn)
                    response = apply_request(
                        request=request,
                        get_state=self._get_state,
                        commands=self._commands,
                    )
                    try:
                        conn.sendall(json.dumps(response).encode("utf-8"))
                    except BrokenPipeError:
                        self._log("Control client disconnected before receiving response.")
            self._server = None
            self._remove_stale_socket()

    def _read_request(self, conn: socket.socket) -> JsonDict:
        chunks: list[bytes] = []
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
        if not chunks:
            self._log("Control server received an empty request.")
            return {}
        try:
            return json.loads(b"".join(chunks).decode("utf-8"))
        except Exception as exc:
            self._log(f"Control server request decode failed: {exc}")
            return {}
