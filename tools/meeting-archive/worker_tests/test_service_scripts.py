from __future__ import annotations

import unittest
import re
import xml.etree.ElementTree as ET
from pathlib import Path


WORKER_ROOT = Path(__file__).resolve().parents[1] / "worker"


class ServiceScriptContractTests(unittest.TestCase):
    def test_background_services_run_the_consent_app_with_fixed_modes(self) -> None:
        for script, mode in (("install-service-bruce.sh", "--worker"),
                             ("install-viewer-service-bruce.sh", "--viewer")):
            with self.subTest(script=script):
                installer = (WORKER_ROOT / script).read_text(encoding="utf-8")
                template = re.search(r"(<\?xml.*?</plist>)", installer, re.S).group(1)
                nodes = list(ET.fromstring(template).find("dict"))
                properties = {nodes[i].text: nodes[i + 1] for i in range(0, len(nodes), 2)}
                arguments = [item.text for item in properties["ProgramArguments"]]
                self.assertEqual(arguments, ["${LAUNCHER}", mode])
                self.assertIn('Meeting Archive Worker.app/Contents/MacOS/meeting-archive-worker', installer)
                self.assertIn('[[ -x "${LAUNCHER}" && ! -L "${LAUNCHER}" ]]', installer)

    def test_worker_installer_stages_private_bounded_stderr_diagnostics(self) -> None:
        installer = (WORKER_ROOT / "install-service-bruce.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn(
            'readonly LOG_DIRECTORY="${HOME}/Library/Logs/Meeting Archive"',
            installer,
        )
        self.assertIn('readonly STDERR_LOG="${LOG_DIRECTORY}/worker.stderr.log"', installer)
        self.assertIn('/bin/chmod 700 "${LOG_DIRECTORY}"', installer)
        self.assertIn('/bin/chmod 600 "${STDERR_LOG}"', installer)
        self.assertIn('"${STDERR_LOG}.previous"', installer)
        self.assertIn('[[ -e "${STDERR_LOG}" || -L "${STDERR_LOG}" ]]', installer)
        self.assertIn(
            '[[ -e "${PREVIOUS_STDERR_LOG}" || -L "${PREVIOUS_STDERR_LOG}" ]]',
            installer,
        )
        self.assertIn('<string>${STDERR_LOG}</string>', installer)
        self.assertIn("<key>StandardOutPath</key>", installer)
        self.assertIn("<string>/dev/null</string>", installer)

    def test_worker_wrapper_does_not_print_loaded_credentials(self) -> None:
        wrapper = (WORKER_ROOT / "run-service-bruce.sh").read_text(encoding="utf-8")

        self.assertNotIn("echo \"${HF_TOKEN}", wrapper)
        self.assertNotIn("echo \"${MEETING_ARCHIVE_NOTION_TOKEN}", wrapper)
        self.assertNotIn("set -x", wrapper)

    def test_worker_wrapper_failures_reach_stderr_and_unified_logging(self) -> None:
        wrapper = (WORKER_ROOT / "run-service-bruce.sh").read_text(encoding="utf-8")
        fail_body = re.search(r"fail\(\) \{(.*?)\n\}", wrapper, re.S).group(1)

        self.assertIn("printf 'Meeting Archive worker: %s\\n' \"$1\" >&2", fail_body)
        self.assertIn('log_error "$1"', fail_body)


if __name__ == "__main__":
    unittest.main()
