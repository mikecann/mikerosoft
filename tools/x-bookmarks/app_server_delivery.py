"""Short-lived stdio app-server delivery using the public JSON-RPC protocol.

Desktop excludes `exec` sessions from its sidebar catalogue. App-server tasks
are eligible for discovery and support naming through thread/name/set.
"""
import json
import os
import re
import selectors
import subprocess
import time
import uuid

from bookmarks import CaptureError, private_json, prompt_for
from cli_delivery import cli_environment


def research_config(effective):
    # A bookmark is permission to research the public web, not to use private
    # connectors, shell commands, or hooks from the user's interactive setup.
    result = {'web_search': 'live', 'features.apps': False,
              'features.plugins': False, 'features.hooks': False,
              'features.shell_tool': False, 'features.memories': False}
    for name in effective.get('mcp_servers', {}):
        result[f'mcp_servers.{name}.enabled'] = False
    return result


def title_from_brief(brief, fallback):
    first = next((line.strip() for line in brief.splitlines() if line.strip()), fallback)
    first = re.sub(r'^#{1,6}\s*', '', first).strip('*` "')
    return ' '.join(first.split())[:100] or fallback


class AppServer:
    def __init__(self, config):
        self.sequence = 0
        self.buffer = b''
        self.notifications = []
        self.proc = subprocess.Popen(
            [config.get('codex_binary', 'codex'), 'app-server', '--stdio'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=cli_environment(config))
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.proc.stdout, selectors.EVENT_READ)
        try:
            self.call('initialize', {'clientInfo': {'name': 'x_bookmarks', 'version': '0.2.0'},
                                     'capabilities': {'experimentalApi': True}})
            self.send({'method': 'initialized'})
        except BaseException:
            self.close()
            raise

    def send(self, value):
        self.proc.stdin.write(json.dumps(value).encode() + b'\n')
        self.proc.stdin.flush()

    def receive(self, deadline):
        while time.monotonic() < deadline:
            if b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                try:
                    message = json.loads(line)
                except (ValueError, UnicodeDecodeError):
                    raise CaptureError('Invalid app-server output; inspect saved delivery') from None
                if 'id' in message and 'method' in message:
                    self.send({'id': message['id'], 'error': {'code': -32601,
                              'message': 'Unattended research does not support client requests'}})
                    continue
                return message
            if not self.selector.select(max(0, deadline - time.monotonic())):
                break
            chunk = os.read(self.proc.stdout.fileno(), 65536)
            if not chunk:
                raise CaptureError('Codex app-server disconnected; inspect saved delivery')
            self.buffer += chunk
            if len(self.buffer) > 8 * 1024 * 1024:
                raise CaptureError('Unexpected app-server output size')
        raise CaptureError('Codex app-server timed out; inspect saved delivery before retrying')

    def call(self, method, params):
        self.sequence += 1
        sequence = self.sequence
        self.send({'id': sequence, 'method': method, 'params': params})
        deadline = time.monotonic() + 60
        while True:
            response = self.receive(deadline)
            if response.get('id') == sequence and 'method' not in response:
                if 'error' in response:
                    # Server errors can contain private context. Keep logs minimal.
                    raise CaptureError(f'Codex {method} failed (code {response["error"].get("code")})')
                return response['result']
            if response.get('method') in ('item/completed', 'turn/completed', 'error'):
                self.notifications.append(response)

    def wait_for_turn(self, thread, turn, timeout=900):
        deadline = time.monotonic() + timeout
        brief = ''
        while True:
            event = self.notifications.pop(0) if self.notifications else self.receive(deadline)
            params = event.get('params', {})
            if params.get('threadId') != thread or params.get('turnId', turn) != turn:
                continue
            if event.get('method') == 'item/completed':
                item = params.get('item', {})
                if item.get('type') == 'agentMessage' and item.get('phase') != 'commentary':
                    brief = item.get('text', '')
            elif event.get('method') == 'turn/completed':
                completed = params.get('turn', {})
                if completed.get('id') != turn:
                    continue
                if completed.get('status') != 'completed' or completed.get('error'):
                    raise CaptureError('Codex research failed; inspect its saved task')
                if not brief.strip():
                    raise CaptureError('Codex completed without a research brief; inspect its saved task')
                return brief

    def close(self):
        self.selector.close()
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.proc.stdin.close()
        self.proc.stdout.close()


def deliver_app_server(store, config, limit=5):
    rows = store.db.execute("SELECT * FROM bookmarks WHERE status='pending' ORDER BY discovered_at LIMIT ?",
                            (limit,)).fetchall()
    if not rows:
        return
    rpc = AppServer(config)
    try:
        for row in rows:
            item = json.loads(row['payload'])
            folder = store.root / 'tasks' / item['id']
            folder.mkdir(parents=True, exist_ok=True, mode=0o700)
            private_json(folder / 'bookmark.json', item)
            effective = rpc.call('config/read', {'cwd': str(folder), 'includeLayers': False})['config']
            params = {'cwd': str(folder), 'sandbox': 'read-only', 'approvalPolicy': 'never',
                      'ephemeral': False, 'config': research_config(effective)}
            if config.get('codex_model'):
                params['model'] = config['codex_model']
            # Save uncertainty before sending a non-idempotent creation request.
            store.update(item['id'], 'creating')
            thread = rpc.call('thread/start', params)['thread']
            thread_id = thread['id']
            try:
                uuid.UUID(thread_id)
            except (ValueError, TypeError, AttributeError):
                raise CaptureError('Codex returned an invalid task ID') from None
            store.update(item['id'], 'created', thread_id)
            if thread.get('source') not in ('appServer', 'vscode', 'cli'):
                raise CaptureError('Codex task source is not sidebar eligible; inspect saved delivery')
            fallback = title_from_brief(item['text'], f"Bookmark by @{item['username']}")
            rpc.call('thread/name/set', {'threadId': thread_id, 'name': fallback})
            store.update(item['id'], 'submitting')
            turn = rpc.call('turn/start', {'threadId': thread_id,
                            'input': [{'type': 'text', 'text': prompt_for(item)}]})['turn']['id']
            brief = rpc.wait_for_turn(thread_id, turn)
            rpc.call('thread/name/set', {'threadId': thread_id,
                                        'name': title_from_brief(brief, fallback)})
            store.update(item['id'], 'delivered')
    finally:
        rpc.close()
