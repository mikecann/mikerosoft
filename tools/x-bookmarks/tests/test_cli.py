import contextlib
import io
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bookmarks import main, private_json, Store, Rpc, CaptureError, request_json, ApiError
from urllib.error import HTTPError


class CliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        private_json(self.root / "config.json", {"allow_paid_x_api": True, "enable_experimental_codex_delivery": True})

    def run_main(self, command):
        with patch.object(sys, "argv", ["x-bookmarks", "--state-dir", str(self.root), command]), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return main()

    def test_unchanged_poll_opens_no_codex_and_throttle_survives_invocations(self):
        with patch("bookmarks.XApi") as api, patch("bookmarks.Rpc") as rpc:
            api.return_value.get.side_effect = [{"data": {"id": "42"}}, {"meta": {"result_count": 0}}]
            self.assertIsNone(self.run_main("tick"))
            self.assertIsNone(self.run_main("tick"))
            self.assertEqual(api.return_value.get.call_count, 2)
            rpc.assert_not_called()

    def test_cli_tick_with_no_new_bookmarks_never_starts_a_process(self):
        private_json(self.root / "config.json", {"allow_paid_x_api": True,
            "enable_experimental_codex_delivery": True, "delivery_backend": "cli"})
        with patch("bookmarks.XApi") as api, patch("cli_delivery.subprocess.Popen") as proc:
            api.return_value.get.side_effect = [{"data": {"id": "42"}}, {"meta": {"result_count": 0}}]
            self.run_main("tick")
            self.run_main("tick")
            proc.assert_not_called()

    def test_429_backoff_is_persisted_and_no_codex_called(self):
        with patch("bookmarks.XApi") as api, patch("bookmarks.Rpc") as rpc:
            api.return_value.get.side_effect = ApiError(429, 1800)
            self.assertEqual(self.run_main("tick"), 1)
            self.assertIsNone(self.run_main("tick"))
            api.return_value.get.assert_called_once()
            rpc.assert_not_called()
        store = Store(self.root)
        self.addCleanup(store.close)
        self.assertEqual(store.get("failures"), "1")

    def test_http_error_never_exposes_token_or_body(self):
        error = HTTPError("https://api.x.com/private?secret=secret-value", 401, "private body", {}, None)
        with patch("bookmarks.urllib.request.build_opener") as opener:
            opener.return_value.open.side_effect = error
            with self.assertRaises(ApiError) as raised:
                request_json("https://api.x.com/2/users/me", {"Authorization": "Bearer secret-value"})
            self.assertNotIn("secret-value", str(raised.exception))
            self.assertNotIn("private body", str(raised.exception))

    def test_direct_login_reports_missing_client_without_traceback(self):
        script = Path(__file__).resolve().parents[1] / "bookmarks.py"
        result = subprocess.run([sys.executable, str(script), "--state-dir", str(self.root), "login"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Set client_id", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_real_subprocess_rpc_handles_notifications_and_disconnect(self):
        fake = self.root / "fake-codex"
        fake.write_text("#!" + sys.executable + "\n" + '''
import json,sys
assert sys.argv[1:] == ['app-server', 'proxy']
for line in sys.stdin:
    request = json.loads(line)
    if 'id' not in request: continue
    if request['method'] == 'disconnect': sys.exit(0)
    print(json.dumps({'method':'ignored','params':{}}))
    print(json.dumps({'id':request['id'],'result':{'ok':True}}), flush=True)
''')
        fake.chmod(0o700)
        rpc = Rpc(str(fake), timeout=2)
        self.addCleanup(rpc.close)
        self.assertEqual(rpc.call("probe", {}), {"ok": True})
        with self.assertRaises(CaptureError):
            rpc.call("disconnect", {})
