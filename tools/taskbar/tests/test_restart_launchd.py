import pathlib
import plistlib
import re
import unittest


TASKBAR_DIR = pathlib.Path(__file__).resolve().parents[1]
RESTART_SCRIPT = TASKBAR_DIR / "restart.sh"


def app_bundle_plist():
    source = RESTART_SCRIPT.read_text(encoding="utf-8")
    match = re.search(
        r'cat >"\$APP_DIR/Contents/Info\.plist" <<PLIST\n(?P<plist>.*?)\nPLIST',
        source,
        re.DOTALL,
    )
    if match is None:
        raise AssertionError("restart.sh app bundle plist heredoc not found")

    return plistlib.loads(match.group("plist").encode("utf-8"))


def runtime_launchd_plist():
    source = RESTART_SCRIPT.read_text(encoding="utf-8")
    match = re.search(
        r'cat >"\$PLIST" <<PLIST\n(?P<plist>.*?)\nPLIST',
        source,
        re.DOTALL,
    )
    if match is None:
        raise AssertionError("restart.sh runtime launchd plist heredoc not found")

    rendered = match.group("plist")
    for variable, value in {
        "$LABEL": "com.mikerosoft.taskbar",
        "$APP_BIN": "/tmp/taskbar-swift",
        "$LOG": "/tmp/mikerosoft-taskbar.log",
    }.items():
        rendered = rendered.replace(variable, value)

    return plistlib.loads(rendered.encode("utf-8"))


class RestartLaunchdTests(unittest.TestCase):
    def test_staged_app_bundle_includes_its_icon(self):
        plist = app_bundle_plist()
        source = RESTART_SCRIPT.read_text(encoding="utf-8")

        self.assertEqual("TaskbarIcon", plist["CFBundleIconFile"])
        self.assertIn(
            'cp "$SCRIPT_DIR/icons/TaskbarIcon.icns" "$APP_DIR/Contents/Resources/TaskbarIcon.icns"',
            source,
        )

    def test_runtime_service_relaunches_only_after_unsuccessful_exit(self):
        plist = runtime_launchd_plist()

        self.assertEqual(
            {"SuccessfulExit": False},
            plist["KeepAlive"],
        )


if __name__ == "__main__":
    unittest.main()
