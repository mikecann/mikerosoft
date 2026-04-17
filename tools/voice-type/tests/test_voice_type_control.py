import importlib.util
import pathlib
import sys
import tempfile
import time
import unittest


TOOLS_DIR = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = TOOLS_DIR / "voice_type_control.py"


def load_module():
    spec = importlib.util.spec_from_file_location("voice_type_control", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class VoiceTypeControlTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module()

    def test_apply_request_returns_state_for_get_state(self):
        state = {"enabled": True, "ui_state": "idle"}
        response = self.module.apply_request(
            request={"command": "get_state"},
            get_state=lambda: state,
            commands={},
        )
        self.assertTrue(response["ok"])
        self.assertEqual(state, response["state"])

    def test_apply_request_dispatches_mutating_command(self):
        seen = {}
        current_state = {"enabled": True}

        def handle_toggle(request):
            seen["request"] = request
            current_state["enabled"] = False

        response = self.module.apply_request(
            request={"command": "toggle_enabled"},
            get_state=lambda: dict(current_state),
            commands={"toggle_enabled": handle_toggle},
        )
        self.assertTrue(response["ok"])
        self.assertEqual({"command": "toggle_enabled"}, seen["request"])
        self.assertFalse(response["state"]["enabled"])

    def test_apply_request_rejects_unknown_command(self):
        response = self.module.apply_request(
            request={"command": "nope"},
            get_state=lambda: {"enabled": True},
            commands={},
        )
        self.assertFalse(response["ok"])
        self.assertEqual("unknown-command:nope", response["error"])

    def test_control_server_round_trip(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            socket_path = str(pathlib.Path(tmpdir) / "voice-type.sock")
            state = {"enabled": True, "ui_state": "idle"}

            def handle_set_mode(request):
                state["ui_state"] = request["value"]

            server = self.module.ControlServer(
                socket_path=socket_path,
                get_state=lambda: dict(state),
                commands={"set_state": handle_set_mode},
                log=lambda _msg: None,
            )
            server.start()
            try:
                deadline = time.time() + 1.0
                while not pathlib.Path(socket_path).exists():
                    if time.time() > deadline:
                        self.fail("socket file was not created")
                    time.sleep(0.01)

                response = self.module.send_request(
                    socket_path,
                    {"command": "set_state", "value": "processing"},
                )
                self.assertTrue(response["ok"])
                self.assertEqual("processing", response["state"]["ui_state"])
            finally:
                server.stop()


if __name__ == "__main__":
    unittest.main()
