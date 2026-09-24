import json
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from bookmarks import Store, CaptureError, resolve_delivery
from app_server_delivery import deliver_app_server, research_config, title_from_brief

ITEM = {'id':'123','username':'tester','author':'Test','text':'Saved post','url':'https://x.com/tester/status/123'}
THREAD = '01a0a392-9ba6-7de0-9910-e8acbca11275'

class FakeServer:
    source = 'appServer'
    fail_turn = False
    fail_name = False
    calls = []
    def __init__(self, config): pass
    def close(self): pass
    def call(self, method, params):
        self.calls.append((method, params))
        if method == 'config/read': return {'config': {'mcp_servers': {'private': {'command':'secret'}}}}
        if method == 'thread/start': return {'thread': {'id':THREAD,'source':self.source}}
        if method == 'thread/name/set' and self.fail_name: raise CaptureError('rename failed')
        if method == 'turn/start': return {'turn':{'id':'turn-one'}}
        return {}
    def wait_for_turn(self, thread, turn, timeout=900):
        if self.fail_turn: raise CaptureError('interrupted')
        return '# Specific research title\n\nResearch findings.'

class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.store=Store(self.tmp.name);self.addCleanup(self.store.close)
        self.store.db.execute('INSERT INTO bookmarks VALUES (?, ?, ?, NULL, ?)',('123',json.dumps(ITEM),'pending',1))
        self.store.db.commit()
        FakeServer.source='appServer';FakeServer.fail_turn=False;FakeServer.fail_name=False;FakeServer.calls=[]
        self.patcher=patch('app_server_delivery.AppServer',FakeServer);self.patcher.start();self.addCleanup(self.patcher.stop)

    def test_creates_sidebar_eligible_task_and_sets_generated_title(self):
        deliver_app_server(self.store,{})
        self.assertEqual(self.store.row('123')['status'],'delivered')
        self.assertEqual(self.store.row('123')['thread_id'],THREAD)
        start=next(p for m,p in FakeServer.calls if m=='thread/start')
        self.assertEqual(start['sandbox'],'read-only')
        self.assertEqual(start['approvalPolicy'],'never')
        self.assertFalse(start['ephemeral'])
        self.assertEqual(FakeServer.calls[-1],('thread/name/set',{'threadId':THREAD,'name':'Specific research title'}))
        n=len(FakeServer.calls);deliver_app_server(self.store,{})
        self.assertEqual(len(FakeServer.calls),n)

    def test_exec_source_is_rejected_and_id_preserved_without_turn(self):
        FakeServer.source='exec'
        with self.assertRaises(CaptureError):deliver_app_server(self.store,{})
        self.assertEqual(self.store.row('123')['thread_id'],THREAD)
        self.assertFalse(any(m=='turn/start' for m,p in FakeServer.calls))

    def test_failed_turn_keeps_recoverable_id_and_never_retries(self):
        FakeServer.fail_turn=True
        with self.assertRaises(CaptureError):deliver_app_server(self.store,{})
        self.assertEqual(self.store.row('123')['status'],'submitting')
        n=len(FakeServer.calls);deliver_app_server(self.store,{})
        self.assertEqual(len(FakeServer.calls),n)

    def test_rename_failure_is_not_success(self):
        FakeServer.fail_name=True
        with self.assertRaises(CaptureError):deliver_app_server(self.store,{})
        self.assertNotEqual(self.store.row('123')['status'],'delivered')
        resolve_delivery(self.store, '123', 'captured', THREAD)
        self.assertEqual(self.store.row('123')['status'], 'delivered')

    def test_research_disables_private_tools_and_inherits_no_mcp_secrets(self):
        result=research_config({'mcp_servers': {'private':{'env':{'SECRET':'secret'}}}})
        self.assertEqual(result['mcp_servers.private.enabled'],False)
        self.assertNotIn('secret',json.dumps(result))
        self.assertFalse(result['features.apps'])
        self.assertFalse(result['features.plugins'])
        self.assertFalse(result['features.shell_tool'])
        self.assertEqual(result['web_search'],'live')

    def test_title_is_bounded_single_line(self):
        self.assertEqual(title_from_brief('# Useful title\n\nOther text','fallback'),'Useful title')
        self.assertEqual(title_from_brief('', 'fallback'),'fallback')
        self.assertLessEqual(len(title_from_brief('# '+('x'*300),'fallback')),100)

class ProtocolTests(unittest.TestCase):
    def test_notifications_before_response_and_failed_turn(self):
        from app_server_delivery import AppServer
        with tempfile.TemporaryDirectory() as tmp:
            binary=pathlib.Path(tmp)/'codex'
            binary.write_text('#!'+sys.executable+'\n'+'''
import json,sys
assert sys.argv[1:] == ['app-server','--stdio']
for line in sys.stdin:
    r=json.loads(line)
    if 'method' not in r or 'id' not in r:continue
    m=r['method'];result={}
    if m=='turn/start':
        for event in [
          {'method':'item/completed','params':{'threadId':'thread','turnId':'turn','item':{'type':'agentMessage','phase':'final_answer','text':'# Research title'}}},
          {'method':'turn/completed','params':{'threadId':'thread','turn':{'id':'turn','status':r['params'].get('status','completed')}}}]:
            print(json.dumps(event))
        result={'turn':{'id':'turn'}}
    print(json.dumps({'id':r['id'],'result':result}),flush=True)
''')
            binary.chmod(0o700)
            rpc=AppServer({'codex_binary':str(binary)})
            try:
                rpc.call('turn/start',{})
                self.assertEqual(rpc.wait_for_turn('thread','turn'),'# Research title')
                rpc.call('turn/start',{'status':'failed'})
                with self.assertRaises(CaptureError):rpc.wait_for_turn('thread','turn')
            finally:rpc.close()
