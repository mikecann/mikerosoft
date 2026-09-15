import json
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from bookmarks import Store, CaptureError
from cli_delivery import deliver_cli

ITEM = {'id':'123', 'username':'tester','author':'Test','text':'Saved post','url':'https://x.com/tester/status/123'}

class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = Store(self.tmp.name)
        self.addCleanup(self.store.close)
        with self.store.db:
            self.store.db.execute('INSERT INTO bookmarks VALUES (?, ?, ?, NULL, ?)', ('123',json.dumps(ITEM),'pending',1))

    def fake(self, outcome):
        def run(config, folder, prompt, on_thread):
            self.assertEqual(self.store.row('123')['status'], 'creating')
            self.assertIn('Saved post', prompt)
            on_thread('01a0a392-9ba6-7de0-9910-e8acbca11275')
            self.assertEqual(self.store.row('123')['status'], 'submitting')
            if outcome == 'fail': raise CaptureError('interrupted')
        return run

    def test_completed_delivery_is_never_repeated(self):
        with patch('cli_delivery.run_cli', self.fake('ok')):
            deliver_cli(self.store, {})
        self.assertEqual(self.store.row('123')['status'], 'delivered')
        with patch('cli_delivery.run_cli') as runner:
            deliver_cli(self.store, {})
            runner.assert_not_called()

    def test_uncertain_turn_keeps_id_and_is_not_retried(self):
        with patch('cli_delivery.run_cli', self.fake('fail')):
            with self.assertRaises(CaptureError): deliver_cli(self.store, {})
        self.assertEqual(self.store.row('123')['status'], 'submitting')
        self.assertIsNotNone(self.store.row('123')['thread_id'])
        with patch('cli_delivery.run_cli') as runner:
            deliver_cli(self.store, {})
            runner.assert_not_called()

    def test_missing_id_stays_uncertain(self):
        with patch('cli_delivery.run_cli', side_effect=CaptureError('lost output')):
            with self.assertRaises(CaptureError): deliver_cli(self.store,{})
        self.assertEqual(self.store.row('123')['status'], 'creating')

    def test_real_process_events_and_nonzero_exit(self):
        from cli_delivery import run_cli
        executable = pathlib.Path(self.tmp.name) / 'codex'
        executable.write_text('#!' + sys.executable + '\n' + '''
import json,sys
assert 'app-server' not in sys.argv
assert '--json' in sys.argv and '--sandbox' in sys.argv
assert 'web_search="live"' in sys.argv
prompt = sys.stdin.read()
print(json.dumps({'type':'thread.started','thread_id':'01a0a392-9ba6-7de0-9910-e8acbca11275'}), flush=True)
if prompt == 'fail': sys.exit(1)
print(json.dumps({'type':'turn.completed'}), flush=True)
''')
        executable.chmod(0o700)
        seen = []
        run_cli({'codex_binary':str(executable)}, self.tmp.name, 'hello', seen.append)
        self.assertEqual(len(seen), 1)
        with self.assertRaises(CaptureError):
            run_cli({'codex_binary':str(executable)}, self.tmp.name, 'fail', seen.append)

    def test_background_environment_includes_codex_node_directory(self):
        from cli_delivery import cli_environment
        with patch.dict('os.environ', {'PATH':'/usr/bin:/bin', 'CODEX_THREAD_ID':'parent', 'CODEX_HOME':'/private/codex'}, clear=True):
            env = cli_environment({'codex_binary':'/custom/node/bin/codex'})
        self.assertEqual(env['PATH'].split(':')[0], '/custom/node/bin')
        self.assertNotIn('CODEX_THREAD_ID', env)
        self.assertEqual(env['CODEX_HOME'], '/private/codex')
