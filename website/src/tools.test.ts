import assert from 'node:assert/strict';
import test from 'node:test';
import { filterToolsByPlatforms, type PlatformId, type Tool } from './tools.ts';

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
