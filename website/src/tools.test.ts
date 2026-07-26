import assert from 'node:assert/strict';
import test from 'node:test';
import { filterToolsByPlatforms, tools, type PlatformId, type Tool } from './tools.ts';

const fixtures: Tool[] = [
  {
    name: 'windows-only',
    desc: '',
    icon: '',
    screenshots: [],
    url: '',
    platforms: ['windows'],
  },
  {
    name: 'mac-only',
    desc: '',
    icon: '',
    screenshots: [],
    url: '',
    platforms: ['macos'],
  },
  {
    name: 'cross-platform',
    desc: '',
    icon: '',
    screenshots: [],
    url: '',
    platforms: ['windows', 'macos'],
  },
];

function namesFor(platforms: readonly PlatformId[]): string[] {
  return filterToolsByPlatforms(fixtures, platforms).map(tool => tool.name);
}

test('shows all tools when both platform toggles are active', () => {
  assert.deepEqual(namesFor(['windows', 'macos']), [
    'windows-only',
    'mac-only',
    'cross-platform',
  ]);
});

test('shows tools available on the one active platform', () => {
  assert.deepEqual(namesFor(['windows']), ['windows-only', 'cross-platform']);
  assert.deepEqual(namesFor(['macos']), ['mac-only', 'cross-platform']);
});

test('shows no tools when both platform toggles are inactive', () => {
  assert.deepEqual(namesFor([]), []);
});

test('publishes Last Window Quits as a documented macOS tool', () => {
  const tool = tools.find(candidate => candidate.name === 'last-window-quits');

  assert.ok(tool);
  assert.deepEqual(tool.platforms, ['macos']);
  assert.match(tool.header ?? '', /last-window-quits\/docs\/header\.webp$/);
  assert.match(tool.url, /tools\/last-window-quits$/);
});

test('publishes Token Stats as a documented macOS tool', () => {
  const tool = tools.find(candidate => candidate.name === 'token-stats');

  assert.ok(tool);
  assert.deepEqual(tool.platforms, ['macos']);
  assert.match(tool.header ?? '', /token-stats\/docs\/header\.png$/);
  assert.match(tool.url, /tools\/token-stats$/);
});
