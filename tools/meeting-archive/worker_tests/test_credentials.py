import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "worker"))
from meeting_archive_worker.credentials import CredentialError, load_credentials


class CredentialTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.root.chmod(0o700)
        self.path = self.root / "credentials.json"
        self.path.write_text(json.dumps({"huggingFaceToken": "private-hf", "notionToken": "private-notion"}))
        self.path.chmod(0o600)

    def tearDown(self):
        self.temporary.cleanup()

    def test_loads_private_credentials_without_replacing_explicit_environment(self):
        environment = {"HF_TOKEN": "explicit"}
        load_credentials(self.path, environment)
        self.assertEqual(environment, {"HF_TOKEN": "explicit", "MEETING_ARCHIVE_NOTION_TOKEN": "private-notion"})

    def test_rejects_group_or_world_readable_file(self):
        self.path.chmod(0o644)
        with self.assertRaises(CredentialError):
            load_credentials(self.path, {})

    def test_rejects_symlinked_file_or_parent_directory(self):
        link = self.root / "link.json"
        link.symlink_to(self.path)
        with self.assertRaises(CredentialError):
            load_credentials(link, {})
        alias = self.root / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(CredentialError):
            load_credentials(alias / "credentials.json", {})

    def test_malformed_input_does_not_leak_values_or_partially_set_environment(self):
        self.path.write_text('{"huggingFaceToken":"private-hf","notionToken":')
        environment = {}
        with self.assertRaises(CredentialError) as raised:
            load_credentials(self.path, environment)
        self.assertNotIn("private-hf", str(raised.exception))
        self.assertEqual(environment, {})

    def test_rejects_incomplete_or_oversized_credentials(self):
        for value in ({"huggingFaceToken": "private-hf"}, {"huggingFaceToken": "x" * 20000, "notionToken": "private-notion"}):
            self.path.write_text(json.dumps(value))
            with self.assertRaises(CredentialError):
                load_credentials(self.path, {})


if __name__ == "__main__":
    unittest.main()
