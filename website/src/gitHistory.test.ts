import assert from 'node:assert/strict';
import test from 'node:test';
import { changesTool, isToolFile, LOG_FORMAT, parseGitLog, toolDatesFromCommits, type Commit } from './gitHistory.ts';

function logEntry(hash: string, date: string, subject: string, body: string, files: string[]): string {
  return `\0${hash}\x1f${date}\x1f${subject}\x1f${body}\x1f\n${files.join('\n')}\n`;
}

function commit(date: string, files: string[], subject = 'A change'): Commit {
  return { hash: date, date, subject, body: '', files };
}

test('the git format separates fields with unit separators', () => {
  assert.equal(LOG_FORMAT, '%x00%H%x1f%cI%x1f%s%x1f%b%x1f');
});

test('parses a tool repo log into commits with repo-root paths', () => {
  const log = [
    logEntry('bbb', '2026-09-02T10:00:00+10:00', 'Second', 'Why.\n', ['src/App.swift', 'docs/ss1.png']),
    logEntry('aaa', '2026-09-01T10:00:00+10:00', 'First', '', ['README.md']),
  ].join('');

  assert.deepEqual(parseGitLog(log), [
    { hash: 'bbb', date: '2026-09-02T10:00:00+10:00', subject: 'Second', body: 'Why.\n', files: ['src/App.swift', 'docs/ss1.png'] },
    { hash: 'aaa', date: '2026-09-01T10:00:00+10:00', subject: 'First', body: '', files: ['README.md'] },
  ]);
});

test('docs, the README, agent notes, the licence and CI are not the tool', () => {
  for (const path of ['docs/header.webp', 'docs/ss1.png', 'README.md', 'AGENTS.md', 'LICENSE', '.github/workflows/ci.yml']) {
    assert.equal(isToolFile(path), false, path);
  }
  for (const path of ['main.py', 'src/App.swift', 'tests/README.md', 'install.ps1', 'icons/picture.png', '.gitignore']) {
    assert.equal(isToolFile(path), true, path);
  }
});

test('paths are relative to the tool repo, not the old tools/<name>/ folder', () => {
  // A folder that happens to be called docs further down is still the tool.
  assert.equal(isToolFile('src/docs/help.md'), true);
  assert.equal(isToolFile('tools/record-it/docs/ss1.png'), true);
});

test('the commit that split a tool into its own repo does not count as a change', () => {
  assert.equal(changesTool(commit('2026-09-30T00:00:00Z', ['install.ps1'], 'Standalone repo: cutout (was removebg)')), false);
  assert.equal(changesTool(commit('2026-09-30T00:00:00Z', ['install.ps1'], 'Fix CI: reset the exit code')), true);
});

test('dates a tool by its first commit and its latest change', () => {
  const dates = toolDatesFromCommits([
    commit('2026-03-05T10:00:00+08:00', ['main.swift', 'README.md']),
    commit('2026-03-01T10:00:00+08:00', ['main.swift']),
  ]);

  assert.deepEqual(dates, { added: '2026-03-01T02:00:00.000Z', updated: '2026-03-05T02:00:00.000Z' });
});

test('the first commit counts as added even if it only touched docs', () => {
  const dates = toolDatesFromCommits([
    commit('2026-02-01T00:00:00Z', ['main.py']),
    commit('2026-01-01T00:00:00Z', ['README.md']),
  ]);

  assert.equal(dates?.added, '2026-01-01T00:00:00.000Z');
  assert.equal(dates?.updated, '2026-02-01T00:00:00.000Z');
});

test('README, docs and the repo split do not move the updated date', () => {
  const dates = toolDatesFromCommits([
    commit('2026-09-30T00:00:00Z', ['install.ps1', 'LICENSE', '.github/workflows/ci.yml'], 'Standalone repo: prepare notes'),
    commit('2026-03-01T00:00:00Z', ['docs/header.webp', 'README.md']),
    commit('2026-01-01T00:00:00Z', ['main.py', 'README.md']),
  ]);

  assert.equal(dates?.added, '2026-01-01T00:00:00.000Z');
  assert.equal(dates?.updated, '2026-01-01T00:00:00.000Z');
});

test('a repo with no history has no dates', () => {
  assert.equal(toolDatesFromCommits([]), undefined);
});
