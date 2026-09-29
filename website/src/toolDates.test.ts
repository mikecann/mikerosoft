import assert from 'node:assert/strict';
import test from 'node:test';
import { formatToolDate, sortTools } from './toolDates.ts';
import type { Tool } from './tools.ts';

function tool(name: string): Tool {
  return { name, desc: '', icon: '', screenshots: [], url: '', platforms: ['macos'] };
}

const toolList = [tool('old'), tool('undated'), tool('new'), tool('middle')];
const dates = {
  old: { added: '2026-02-18T01:00:00.000Z', updated: '2026-09-01T01:00:00.000Z' },
  middle: { added: '2026-05-01T01:00:00.000Z', updated: '2026-05-02T01:00:00.000Z' },
  new: { added: '2026-09-29T01:00:00.000Z', updated: '2026-09-29T02:00:00.000Z' },
};

function names(sorted: Tool[]): string[] {
  return sorted.map(item => item.name);
}

test('default sort keeps the hand-picked order', () => {
  assert.deepEqual(names(sortTools(toolList, dates, 'default', 'newest')), [
    'old',
    'undated',
    'new',
    'middle',
  ]);
});

test('sorts by date added, newest or oldest first', () => {
  assert.deepEqual(names(sortTools(toolList, dates, 'added', 'newest')), [
    'new',
    'middle',
    'old',
    'undated',
  ]);
  assert.deepEqual(names(sortTools(toolList, dates, 'added', 'oldest')), [
    'old',
    'middle',
    'new',
    'undated',
  ]);
});

test('sorts by date updated', () => {
  assert.deepEqual(names(sortTools(toolList, dates, 'updated', 'newest')), [
    'new',
    'old',
    'middle',
    'undated',
  ]);
});

test('does not reorder the list it was given', () => {
  sortTools(toolList, dates, 'added', 'newest');

  assert.deepEqual(names(toolList), ['old', 'undated', 'new', 'middle']);
});

test('formats dates as day, short month, year in the given time zone', () => {
  // 20:00 UTC on 28 September is already 29 September in Perth.
  assert.equal(formatToolDate('2026-09-28T20:00:00.000Z', 'Australia/Perth'), '29 Sep 2026');
  assert.equal(formatToolDate('2026-09-28T20:00:00.000Z', 'UTC'), '28 Sep 2026');
  assert.equal(formatToolDate('2026-06-12T04:00:00.000Z', 'UTC'), '12 Jun 2026');
});
