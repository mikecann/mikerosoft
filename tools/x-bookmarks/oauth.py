"""Read-only PKCE login for an X Native App (public OAuth client)."""
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import secrets
import time
from urllib.parse import parse_qs, urlencode, urlsplit
import webbrowser

from bookmarks import CaptureError, private_json, request_json

CALLBACK = "http://127.0.0.1:8767/callback"
SCOPES = "bookmark.read tweet.read users.read offline.access"


def authorization_url(client_id, state, verifier):
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    return "https://x.com/i/oauth2/authorize?" + urlencode({
        "response_type": "code", "client_id": client_id, "redirect_uri": CALLBACK,
        "scope": SCOPES, "state": state, "code_challenge": challenge, "code_challenge_method": "S256",
    })


def callback_code(path, state):
    url = urlsplit(path)
    params = parse_qs(url.query)
    if (url.path != "/callback" or params.get("state") != [state]
            or "error" in params or len(params.get("code", [])) != 1):
        raise CaptureError("OAuth callback denied or invalid; no credentials saved")
    return params["code"][0]


def login(config):
    if not config.get("client_id"):
        raise CaptureError("Set client_id from an X Native App and register " + CALLBACK)
    verifier, state = secrets.token_urlsafe(48), secrets.token_urlsafe(32)
    result = {}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # Callback URLs contain the authorization code.

        def do_GET(self):
            try:
                code = callback_code(self.path, state)
                token = request_json("https://api.x.com/2/oauth2/token", form={
                    "grant_type": "authorization_code", "client_id": config["client_id"],
                    "redirect_uri": CALLBACK, "code": code, "code_verifier": verifier,
                })
                if (not token.get("access_token") or not token.get("refresh_token")
                        or not token.get("expires_in") or not set(SCOPES.split()) <= set(token.get("scope", "").split())):
                    raise CaptureError("OAuth response missing required scopes or credentials")
                token["expires_at"] = time.time() + token["expires_in"]
                private_json(config["token_file"], token)
                result["ok"] = True
                message = b"X authorization saved. You can close this tab. Polling is not enabled by this login."
                self.send_response(200)
            except (CaptureError, OSError, ValueError, KeyError):
                message = b"Authorization failed. Return to the terminal and try login again."
                self.send_response(400)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(message)

    with HTTPServer(("127.0.0.1", 8767), Handler) as server:
        server.timeout = 1
        if not webbrowser.open(authorization_url(config["client_id"], state, verifier)):
            raise CaptureError("Could not open the browser for X authorization")
        print("Complete X authorization in the browser. Waiting up to three minutes.", flush=True)
        deadline = time.monotonic() + 180
        while not result and time.monotonic() < deadline:
            server.handle_request()
    if not result.get("ok"):
        raise CaptureError("OAuth login timed out; no successful authorization received")
    print("OAuth credentials saved privately. No bookmark API reads or Codex calls made.")
