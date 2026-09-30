import assert from 'node:assert/strict';
import test from 'node:test';
import { changelogFromGitLog, cleanTitle } from './changelog.ts';

function commit(hash: string, date: string, subject: string, body: string, files: string[]): string {
  return `\0${hash}\x1f${date}\x1f${subject}\x1f${body}\x1f\n${files.join('\n')}\n`;
}

test('lists a tool repo\'s commits, newest first', () => {
  const log = [
    commit('aaa', '2026-09-01T10:00:00+10:00', 'Share build fix', 'It broke.', ['build-app.sh']),
    commit('bbb', '2026-09-02T10:00:00+10:00', 'Record It: never stop a take', 'Why it changed.', ['Sources/App.swift']),
  ].join('');

  assert.deepEqual(changelogFromGitLog(log, 'record-it').map(entry => entry.hash), ['bbb', 'aaa']);
});

test('skips commits that only touch docs, screenshots or the README', () => {
  const log = commit('ccc', '2026-09-03T10:00:00+10:00', 'New header', '', ['docs/header.webp', 'README.md']);

  assert.deepEqual(changelogFromGitLog(log, 'record-it'), []);
});

test('skips the commit that split the tool into its own repo', () => {
  const log = [
    commit('split', '2026-09-30T13:16:40+08:00', 'Standalone repo: prepare record-it for independent installation', '', [
      'install.sh',
      'LICENSE',
    ]),
    commit('ci', '2026-09-30T13:28:19+08:00', 'Fix CI: reset a stale exit code', '', ['tests/test-deps.ps1']),
  ].join('');

  assert.deepEqual(changelogFromGitLog(log, 'record-it').map(entry => entry.hash), ['ci']);
});

test('keeps the why from the body and drops trailers', () => {
  const body = [
    'A static screen stopped the take.',
    '',
    '- Ignore screen silence',
    '- Log each problem',
    '',
    'Co-Authored-By: Claude <noreply@anthropic.com>',
  ].join('\n');
  const log = commit('ddd', '2026-09-04T10:00:00+10:00', 'Record It: keep recording', body, ['Sources/App.swift']);

  const [entry] = changelogFromGitLog(log, 'record-it');

  assert.equal(entry.title, 'Keep recording');
  assert.equal(entry.date, '2026-09-04T00:00:00.000Z');
  assert.deepEqual(entry.paragraphs, ['A static screen stopped the take.', '- Ignore screen silence\n- Log each problem']);
});

test('unwraps hard-wrapped commit lines but keeps bullets on their own lines', () => {
  const body = 'Screen recordings shared the\ncamera rate control.\n\n- Ignore screen\n  silence\n- Log each problem';
  const log = commit('eee', '2026-09-05T10:00:00+10:00', 'Wrapped', body, ['a.swift']);

  const [entry] = changelogFromGitLog(log, 'record-it');

  assert.deepEqual(entry.paragraphs, [
    'Screen recordings shared the camera rate control.',
    '- Ignore screen silence\n- Log each problem',
  ]);
});

test('strips the tool name prefix from titles but keeps other prefixes', () => {
  assert.equal(cleanTitle('Tandem app: a quieter UI', 'tandem'), 'A quieter UI');
  assert.equal(cleanTitle('Record It: constant-quality presets', 'record-it'), 'Constant-quality presets');
  assert.equal(cleanTitle('record-it: fix crash', 'record-it'), 'Fix crash');
  assert.equal(cleanTitle('Build scripts: survive empty arrays', 'record-it'), 'Build scripts: survive empty arrays');
  assert.equal(cleanTitle('Add Token Stats macOS usage dashboard', 'token-stats'), 'Add Token Stats macOS usage dashboard');
});

test('strips a renamed tool\'s old name from its older commits', () => {
  const log = commit('fff', '2026-04-01T10:00:00+10:00', 'removebg: use birefnet-portrait', '', ['removebg.bat']);

  assert.equal(changelogFromGitLog(log, 'cutout', 'removebg')[0].title, 'Use birefnet-portrait');
  assert.equal(cleanTitle('Remove Portrait: faster matting', 'video-cutout', 'remove-portrait'), 'Faster matting');
});
