"""One persisted CLI turn per new bookmark. No Desktop IPC or UI automation."""
import json
import os
from pathlib import Path
import selectors
import subprocess
import time
import uuid

from bookmarks import CaptureError, private_json, prompt_for


def cli_environment(config):
    # A launchd worker must not inherit a parent Codex task's session/tool pipe.
    env = {k: v for k, v in os.environ.items() if not k.startswith('CODEX_') or k == 'CODEX_HOME'}
    # npm installs Codex beside Node, but launchd omits that directory. Keep
    # the configured shim path rather than resolving it into node_modules.
    binary = Path(config.get('codex_binary', 'codex')).expanduser()
    if binary.is_absolute():
        env['PATH'] = str(binary.parent) + os.pathsep + env.get('PATH', '/usr/bin:/bin')
    return env


def run_cli(config, folder, prompt, on_thread, *, resume_thread_id=None):
    env = cli_environment(config)
    args = [config.get('codex_binary', 'codex'), 'exec', '--ignore-user-config',
            '-c', 'web_search="live"', '--sandbox', 'read-only', '--skip-git-repo-check', '-C', str(folder), '--json']
    if resume_thread_id:
        uuid.UUID(resume_thread_id)
        args += ['resume', resume_thread_id]
    args += ['-']
    # Preserve an explicitly configured model, otherwise use the CLI default.
    if config.get('codex_model'):
        args[2:2] = ['--model', config['codex_model']]
    with subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, env=env) as proc:
        selector = selectors.DefaultSelector()
        selector.register(proc.stdout, selectors.EVENT_READ)
        completed, thread_id, buffer = False, None, b''
        try:
            proc.stdin.write(prompt.encode())
            proc.stdin.close()
            deadline = time.monotonic() + 900
            while time.monotonic() < deadline:
                if not selector.select(timeout=1):
                    if proc.poll() is not None: break
                    continue
                chunk = os.read(proc.stdout.fileno(), 65536)
                if not chunk: break
                buffer += chunk
                if len(buffer) > 1024 * 1024:
                    raise CaptureError('Unexpected Codex output; inspect the saved task before retrying')
                while b'\n' in buffer:
                    line, buffer = buffer.split(b'\n', 1)
                    try:
                        event = json.loads(line)
                    except (ValueError, UnicodeDecodeError):
                        raise CaptureError('Invalid Codex event; delivery outcome requires inspection') from None
                    kind = event.get('type')
                    if kind == 'thread.started':
                        candidate = event.get('thread_id')
                        try: uuid.UUID(candidate)
                        except (ValueError, TypeError, AttributeError):
                            raise CaptureError('Codex returned an invalid task ID') from None
                        if thread_id and candidate != thread_id:
                            raise CaptureError('Codex returned multiple task IDs')
                        thread_id = candidate
                        on_thread(thread_id)
                    elif kind == 'turn.completed':
                        completed = True
                    elif kind in ('error', 'turn.failed'):
                        raise CaptureError('Codex turn failed; inspect its saved task before retrying')
            if proc.poll() is None:
                try: proc.wait(timeout=max(0.1, deadline - time.monotonic()))
                except subprocess.TimeoutExpired:
                    raise CaptureError('Codex timed out; inspect its saved task before retrying') from None
            if proc.returncode != 0 or not completed or not thread_id:
                raise CaptureError('Codex did not confirm completion; inspect delivery status before retrying')
        finally:
            selector.close()
            if proc.poll() is None:
                proc.terminate()
                try: proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()


def deliver_cli(store, config, limit=5):
    rows = store.db.execute("SELECT * FROM bookmarks WHERE status='pending' ORDER BY discovered_at LIMIT ?", (limit,)).fetchall()
    for row in rows:
        item = json.loads(row['payload'])
        folder = store.root / 'tasks' / item['id']
        folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        private_json(folder / 'bookmark.json', item)
        # Persist intent before starting a process. Crashes never trigger a blind
        # retry, even when the process created a task but its output was lost.
        store.update(item['id'], 'creating')
        def remember(thread_id):
            store.update(item['id'], 'submitting', thread_id)
        run_cli(config, folder, prompt_for(item), remember)
        store.update(item['id'], 'delivered')
