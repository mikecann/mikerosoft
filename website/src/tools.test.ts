import assert from 'node:assert/strict';
import test from 'node:test';
import { existsSync } from 'node:fs';
import {
  CATEGORY_ICON,
  CATEGORY_ORDER,
  filterToolsByPlatforms,
  groupToolsByCategory,
  PLATFORM_ICON,
  searchTools,
  tools,
  type PlatformId,
  type Tool,
} from './tools.ts';

const fixtures: Tool[] = [
  {
    name: 'windows-only',
    desc: '',
    icon: '',
    screenshots: [],
    url: '',
    platforms: ['windows'],
    category: 'Desktop',
  },
  {
    name: 'mac-only',
    desc: '',
    icon: '',
    screenshots: [],
    url: '',
    platforms: ['macos'],
    category: 'Desktop',
  },
  {
    name: 'cross-platform',
    desc: '',
    icon: '',
    screenshots: [],
    url: '',
    platforms: ['windows', 'macos'],
    category: 'Desktop',
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

test('publishes Mikey Mouse as a macOS tool', () => {
  const tool = tools.find(candidate => candidate.name === 'mikey-mouse');

  assert.ok(tool);
  assert.deepEqual(tool.platforms, ['macos']);
  assert.match(tool.header ?? '', /mikey-mouse\/docs\/header\.webp$/);
  assert.match(tool.url, /tools\/mikey-mouse$/);
});

test('publishes Tandem as a documented macOS tool', () => {
  const tool = tools.find(candidate => candidate.name === 'tandem');

  assert.ok(tool);
  assert.deepEqual(tool.platforms, ['macos']);
  assert.match(tool.header ?? '', /tandem\/docs\/header\.jpg$/);
  assert.match(tool.url, /tools\/tandem$/);
});

test('every tool sits in a category, and every category has tools', () => {
  for (const tool of tools) {
    assert.ok(CATEGORY_ORDER.includes(tool.category), `${tool.name} has no category`);
  }
  for (const category of CATEGORY_ORDER) {
    assert.ok(tools.some(tool => tool.category === category), `${category} is empty`);
  }
});

test('groups tools by category in category order, keeping their order within each', () => {
  const groups = groupToolsByCategory(tools);

  assert.deepEqual(
    groups.map(group => group.category),
    CATEGORY_ORDER.filter(category => tools.some(tool => tool.category === category)),
  );
  assert.equal(groups.flatMap(group => group.tools).length, tools.length);
});

test('search matches every word against names, descriptions and categories, names first', () => {
  assert.deepEqual(searchTools(tools, 'RECORD-IT').map(tool => tool.name), ['record-it', 'tandem']);
  assert.ok(searchTools(tools, 'elgato prompter').some(tool => tool.name === 'telemprompit'));
  assert.ok(searchTools(tools, 'developer').some(tool => tool.name === 'worktrees'));
  assert.equal(searchTools(tools, '  ').length, tools.length);
  assert.equal(searchTools(tools, 'zzzznothing').length, 0);
});

test('every tool has its own unique Mikerosoft 95 icon', () => {
  const icons = tools.map(tool => tool.icon);

  assert.equal(new Set(icons).size, tools.length);
  for (const tool of tools) {
    assert.equal(tool.icon, `/icons/${tool.name}.png`);
    assert.ok(existsSync(new URL(`../public/icons/${tool.name}.png`, import.meta.url)), `${tool.name} icon is missing`);
  }
});

test('every category and platform has an icon', () => {
  for (const icon of [...Object.values(CATEGORY_ICON), ...Object.values(PLATFORM_ICON)]) {
    assert.ok(existsSync(new URL(`../public${icon}`, import.meta.url)), `${icon} is missing`);
  }
  assert.deepEqual(Object.keys(CATEGORY_ICON).sort(), [...CATEGORY_ORDER].sort());
});
