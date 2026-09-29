import pathlib
import sys
import unittest
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from oauth import authorization_url, callback_code
from bookmarks import CaptureError


class OAuthTests(unittest.TestCase):
    def test_pkce_scopes_exclude_writes(self):
        url = authorization_url("client", "state", "verifier")
        query = parse_qs(urlparse(url).query)
        self.assertEqual(query["scope"], ["bookmark.read tweet.read users.read offline.access"])
        self.assertEqual(query["code_challenge_method"], ["S256"])
        self.assertNotIn("verifier", url)

    def test_callback_requires_exact_path_and_matching_state(self):
        self.assertEqual(callback_code("/callback?state=expected&code=abc", "expected"), "abc")
        for path in ["/callback?state=wrong&code=abc", "/other?state=expected&code=abc",
                     "/callback?state=expected&error=denied", "/callback?code=abc"]:
            with self.assertRaises(CaptureError):
                callback_code(path, "expected")
