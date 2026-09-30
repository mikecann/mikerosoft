import assert from 'node:assert/strict';
import test from 'node:test';
import { changelogsFromGitLog, cleanTitle, LOG_FORMAT } from './changelog.ts';

function commit(hash: string, date: string, subject: string, body: string, files: string[]): string {
  return `\0${hash}\x1f${date}\x1f${subject}\x1f${body}\x1f\n${files.join('\n')}\n`;
}

test('the git format separates fields with unit separators', () => {
  assert.equal(LOG_FORMAT, '%x00%H%x1f%cI%x1f%s%x1f%b%x1f');
});

test('groups commits by the tools they changed, newest first', () => {
  const log = [
    commit('bbb', '2026-09-02T10:00:00+10:00', 'Record It: never stop a take', 'Why it changed.', [
      'tools/record-it/Sources/App.swift',
    ]),
    commit('aaa', '2026-09-01T10:00:00+10:00', 'Share build fix', 'Both apps broke.', [
      'tools/record-it/build-app.sh',
      'tools/tandem/build-app.sh',
    ]),
  ].join('');

  const changelogs = changelogsFromGitLog(log);

  assert.deepEqual(changelogs['record-it'].map(entry => entry.hash), ['bbb', 'aaa']);
  assert.deepEqual(changelogs.tandem.map(entry => entry.hash), ['aaa']);
});

test('skips commits that only touch docs, screenshots or the README', () => {
  const log = commit('ccc', '2026-09-03T10:00:00+10:00', 'New header', '', [
    'tools/record-it/docs/header.webp',
    'tools/record-it/README.md',
  ]);

  assert.equal(changelogsFromGitLog(log)['record-it'], undefined);
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
  const log = commit('ddd', '2026-09-04T10:00:00+10:00', 'Record It: keep recording', body, [
    'tools/record-it/Sources/App.swift',
  ]);

  const [entry] = changelogsFromGitLog(log)['record-it'];

  assert.equal(entry.title, 'Keep recording');
  assert.equal(entry.date, '2026-09-04T00:00:00.000Z');
  assert.deepEqual(entry.paragraphs, ['A static screen stopped the take.', '- Ignore screen silence\n- Log each problem']);
});

test('unwraps hard-wrapped commit lines but keeps bullets on their own lines', () => {
  const body = 'Screen recordings shared the\ncamera rate control.\n\n- Ignore screen\n  silence\n- Log each problem';
  const log = commit('eee', '2026-09-05T10:00:00+10:00', 'Wrapped', body, ['tools/record-it/a.swift']);

  const [entry] = changelogsFromGitLog(log)['record-it'];

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
