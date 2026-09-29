import assert from 'node:assert/strict';
import test from 'node:test';
import { toolDatesFromGitLog } from './gitHistory.ts';

function commit(time: string, ...changes: string[]): string {
  return `\0${time}\n\n${changes.join('\n')}\n`;
}

test('dates a tool by its first and latest commits', () => {
  const log = [
    commit('2026-03-01T10:00:00+08:00', 'A\ttools/clock/main.swift'),
    commit('2026-03-05T10:00:00+08:00', 'M\ttools/clock/main.swift', 'A\ttools/clock/README.md'),
  ].join('');

  assert.deepEqual(toolDatesFromGitLog(log, ['tools/clock/main.swift', 'tools/clock/README.md']), {
    clock: {
      added: '2026-03-01T02:00:00.000Z',
      updated: '2026-03-05T02:00:00.000Z',
    },
  });
});

test('keeps the original date when a tool moved into tools/ and was renamed', () => {
  const log = [
    commit('2026-02-18T09:00:00+08:00', 'A\ttaskmon/App.cs'),
    commit('2026-04-01T09:00:00+08:00', 'R100\ttaskmon/App.cs\ttools/taskmon/App.cs'),
    commit('2026-05-01T09:00:00+08:00', 'R100\ttools/taskmon/App.cs\ttools/task-stats/App.cs'),
  ].join('');

  const dates = toolDatesFromGitLog(log, ['tools/task-stats/App.cs']);

  assert.equal(dates['task-stats'].added, '2026-02-18T01:00:00.000Z');
  assert.equal(dates['task-stats'].updated, '2026-05-01T01:00:00.000Z');
});

test('ignores files that were deleted before today', () => {
  const log = [
    commit('2026-01-01T00:00:00Z', 'A\ttools/notes/old.txt'),
    commit('2026-02-01T00:00:00Z', 'A\ttools/notes/new.txt'),
    commit('2026-03-01T00:00:00Z', 'D\ttools/notes/old.txt'),
  ].join('');

  const dates = toolDatesFromGitLog(log, ['tools/notes/new.txt']);

  assert.equal(dates.notes.added, '2026-02-01T00:00:00.000Z');
  assert.equal(dates.notes.updated, '2026-03-01T00:00:00.000Z');
});

test('skips merge commits and changes outside tools/', () => {
  const log = [
    commit('2026-01-01T00:00:00Z', 'A\ttools/notes/a.txt', 'A\tREADME.md'),
    commit('2026-06-01T00:00:00Z'),
    commit('2026-07-01T00:00:00Z', 'M\tREADME.md'),
  ].join('');

  assert.deepEqual(toolDatesFromGitLog(log, ['tools/notes/a.txt', 'README.md']), {
    notes: {
      added: '2026-01-01T00:00:00.000Z',
      updated: '2026-01-01T00:00:00.000Z',
    },
  });
});

test('README and docs/ image changes do not count as tool updates', () => {
  const log = [
    commit('2026-01-01T00:00:00Z', 'A\ttools/notes/main.py', 'A\ttools/notes/README.md'),
    commit('2026-02-01T00:00:00Z', 'A\ttools/notes/docs/header.png'),
    commit(
      '2026-03-01T00:00:00Z',
      'D\ttools/notes/docs/header.png',
      'A\ttools/notes/docs/header.webp',
      'M\ttools/notes/README.md',
    ),
  ].join('');

  const dates = toolDatesFromGitLog(log, [
    'tools/notes/main.py',
    'tools/notes/README.md',
    'tools/notes/docs/header.webp',
  ]);

  assert.equal(dates.notes.added, '2026-01-01T00:00:00.000Z');
  assert.equal(dates.notes.updated, '2026-01-01T00:00:00.000Z');
});
